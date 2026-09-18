import AppKit
import ApplicationServices
import SwiftUI

enum WindowTile {
    static func title(_ direction: SwipeDirection) -> String {
        switch direction {
        case .left: return "Left half"
        case .right: return "Right half"
        case .up: return "Maximize"
        case .down: return "Bottom half"
        case .topLeft: return "Top-left quarter"
        case .topRight: return "Top-right quarter"
        case .bottomLeft: return "Bottom-left quarter"
        case .bottomRight: return "Bottom-right quarter"
        }
    }

    // Top-left origin, matching Accessibility's global desktop coordinates.
    static func frame(_ direction: SwipeDirection, in area: CGRect) -> CGRect {
        let halfWidth = floor(area.width / 2), halfHeight = floor(area.height / 2)
        switch direction {
        case .up: return area
        case .left: return CGRect(x: area.minX, y: area.minY, width: halfWidth, height: area.height)
        case .right: return CGRect(x: area.minX + halfWidth, y: area.minY, width: area.width - halfWidth, height: area.height)
        case .down: return CGRect(x: area.minX, y: area.minY + halfHeight, width: area.width, height: area.height - halfHeight)
        case .topLeft: return CGRect(x: area.minX, y: area.minY, width: halfWidth, height: halfHeight)
        case .topRight: return CGRect(x: area.minX + halfWidth, y: area.minY, width: area.width - halfWidth, height: halfHeight)
        case .bottomLeft: return CGRect(x: area.minX, y: area.minY + halfHeight, width: halfWidth, height: area.height - halfHeight)
        case .bottomRight: return CGRect(x: area.minX + halfWidth, y: area.minY + halfHeight, width: area.width - halfWidth, height: area.height - halfHeight)
        }
    }

    static func accessibilityFrame(_ frame: CGRect, primaryTop: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: primaryTop - frame.maxY, width: frame.width, height: frame.height)
    }

    static func screenIndex(for window: CGRect, frames: [CGRect]) -> Int? {
        frames.indices.max { a, b in
            let lhs = window.intersection(frames[a]), rhs = window.intersection(frames[b])
            return (lhs.isNull ? 0 : lhs.width * lhs.height) < (rhs.isNull ? 0 : rhs.width * rhs.height)
        }
    }
}

@MainActor struct WindowTilingTarget {
    // Returns a user-visible error, or nil on success. Injectable for HUD tests.
    var apply: (SwipeDirection) -> String?
}

@MainActor enum WindowTiling {
    static func capture(pid: pid_t) -> WindowTilingTarget? {
        guard AXIsProcessTrusted(), pid != ProcessInfo.processInfo.processIdentifier else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        guard let value = attribute(app, kAXFocusedWindowAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let window = unsafeBitCast(value, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(window, 0.2)
        return WindowTilingTarget { direction in
            guard AXIsProcessTrusted() else { return "Enable Accessibility for Rotagivan, then try again." }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return "The original app is no longer active. Reopen Explorer over that window." }
            if (attribute(window, "AXFullScreen") as? Bool) == true { return "Exit full screen before tiling this window." }
            if (attribute(window, kAXMinimizedAttribute) as? Bool) == true { return "Restore the minimized window first." }
            var movable: DarwinBoolean = false, resizable: DarwinBoolean = false
            guard AXUIElementIsAttributeSettable(window, kAXPositionAttribute as CFString, &movable) == .success,
                  AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &resizable) == .success,
                  movable.boolValue, resizable.boolValue else { return "This window does not support moving and resizing." }
            guard let current = frame(window), let primary = NSScreen.screens.first else { return "The original window is no longer available." }
            let screens = NSScreen.screens
            let frames = screens.map { WindowTile.accessibilityFrame($0.frame, primaryTop: primary.frame.maxY) }
            guard let index = WindowTile.screenIndex(for: current, frames: frames) else { return "No display is available." }
            let area = WindowTile.accessibilityFrame(screens[index].visibleFrame, primaryTop: primary.frame.maxY)
            let desired = WindowTile.frame(direction, in: area)
            // Resize first so a large window can move into an edge/corner, then
            // repeat size after moving for apps that constrain by current position.
            var size = desired.size, point = desired.origin
            guard let sizeValue = AXValueCreate(.cgSize, &size), let pointValue = AXValueCreate(.cgPoint, &point) else { return "Could not calculate the window placement." }
            let firstSize = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
            let position = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, pointValue)
            let finalSize = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
            guard position == .success, firstSize == .success || finalSize == .success else { return "The app could not apply this layout. Try a larger tile or another window." }
            if let actual = frame(window), abs(actual.width - desired.width) > 8 || abs(actual.height - desired.height) > 8 {
                return "This app limits its window size. Try a larger tile."
            }
            return nil
        }
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func frame(_ window: AXUIElement) -> CGRect? {
        guard let position = attribute(window, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = attribute(window, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions),
              point.x.isFinite, point.y.isFinite, dimensions.width.isFinite, dimensions.height.isFinite,
              dimensions.width > 0, dimensions.height > 0 else { return nil }
        return CGRect(origin: point, size: dimensions)
    }
}

struct WindowTileIcon: View {
    let direction: SwipeDirection
    var body: some View {
        let area = CGRect(x: 0, y: 0, width: 42, height: 30)
        let tile = WindowTile.frame(direction, in: area).insetBy(dx: 2, dy: 2)
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4).strokeBorder(.secondary.opacity(0.5))
            RoundedRectangle(cornerRadius: 2).fill(.teal).frame(width: tile.width, height: tile.height)
                .offset(x: tile.minX, y: tile.minY)
        }.frame(width: 42, height: 30).frame(height: 42).accessibilityHidden(true)
    }
}
