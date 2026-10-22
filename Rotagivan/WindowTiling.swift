import AppKit
import ApplicationServices
import SwiftUI

enum WindowTile {
    static func title(_ direction: SwipeDirection, layout: ExplorerWindowLayout = .halves) -> String {
        ExplorerWindowPlacement(direction: direction, layout: layout).title
    }

    // Top-left origin, matching Accessibility's global desktop coordinates.
    static func frame(_ direction: SwipeDirection, in area: CGRect, layout: ExplorerWindowLayout = .halves,
                      backingScale: CGFloat = 1) -> CGRect {
        guard valid(area) else { return .null }
        let scale = backingScale.isFinite && backingScale > 0 ? backingScale : 1
        let denominator: CGFloat = layout == .fourths ? 4 : (layout == .halves ? 2 : 3)
        let numerator: CGFloat = layout == .twoThirds ? 2 : 1
        func boundary(_ length: CGFloat, _ units: CGFloat) -> CGFloat { floor(length * scale * units / denominator) / scale }
        let left = [.left, .topLeft, .bottomLeft].contains(direction)
        let right = [.right, .topRight, .bottomRight].contains(direction)
        let top = [.up, .topLeft, .topRight].contains(direction)
        let bottom = [.down, .bottomLeft, .bottomRight].contains(direction)
        // Derive both sides from the same partition boundaries. The trailing
        // tile owns the remainder, so complementary fractions never leave gaps.
        let x0 = right ? area.minX + boundary(area.width, denominator - numerator) : area.minX
        let x1 = left ? area.minX + boundary(area.width, numerator) : area.maxX
        let y0 = bottom ? area.minY + boundary(area.height, denominator - numerator) : area.minY
        let y1 = top ? area.minY + boundary(area.height, numerator) : area.maxY
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    static func valid(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite && rect.minX.isFinite && rect.minY.isFinite &&
        rect.maxX.isFinite && rect.maxY.isFinite && rect.width > 0 && rect.height > 0
    }

    static func accessibilityFrame(_ frame: CGRect, primaryTop: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: primaryTop - frame.maxY, width: frame.width, height: frame.height)
    }

    static func screenIndex(for window: CGRect, frames: [CGRect]) -> Int? {
        guard valid(window) else { return nil }
        var best: Int?, largest: CGFloat = -1, nearest: CGFloat = .infinity
        for index in frames.indices where valid(frames[index]) {
            let screen = frames[index], overlap = window.intersection(screen)
            let area = overlap.isNull ? 0 : overlap.width * overlap.height
            let dx = max(screen.minX - window.midX, 0, window.midX - screen.maxX)
            let dy = max(screen.minY - window.midY, 0, window.midY - screen.maxY)
            let distance = dx * dx + dy * dy
            if area > largest || (area == largest && distance < nearest) {
                best = index; largest = area; nearest = distance
            }
        }
        return best
    }

    /// Re-anchor the size the app actually accepts, not the size we hoped for.
    /// Independent implementation informed by Rectangle's bounds/alignment ideas.
    static func aligned(_ size: CGSize, requested: CGRect, in area: CGRect, direction: SwipeDirection?) -> CGRect {
        guard valid(area), valid(requested), size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return .null }
        var x = requested.midX - size.width / 2, y = requested.midY - size.height / 2
        if let direction {
            if [.left, .topLeft, .bottomLeft].contains(direction) { x = requested.minX }
            if [.right, .topRight, .bottomRight].contains(direction) { x = requested.maxX - size.width }
            if [.up, .topLeft, .topRight].contains(direction) { y = requested.minY }
            if [.down, .bottomLeft, .bottomRight].contains(direction) { y = requested.maxY - size.height }
        }
        // An oversized window cannot fit both edges. Keep its title bar and
        // left edge reachable instead of pushing the whole window off-screen.
        x = size.width > area.width ? area.minX : min(max(x, area.minX), area.maxX - size.width)
        y = size.height > area.height ? area.minY : min(max(y, area.minY), area.maxY - size.height)
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }
}

/// A testable, bounded settling pipeline. All read/write closures refer to the
/// original AX window; focus loss cancels further writes rather than moving a
/// newly active app. Geometry is in global AX points, never physical pixels.
enum WindowPlacement {
    struct Access {
        var read: () -> CGRect?
        var resize: (CGSize) -> Bool
        var move: (CGPoint) -> Bool
        var minimum: () -> CGSize? = { nil }
        var isCurrent: () -> Bool = { true }
        var pause: () -> Void = { Thread.sleep(forTimeInterval: 0.025) }
    }
    enum Outcome: Equatable {
        case exact, constrained, failed, unavailable, oversized, cancelled
        var error: String? {
            switch self {
            case .exact, .constrained: return nil
            case .failed: return "The app did not accept the window placement. Try another window or a larger tile."
            case .unavailable: return "The original window is no longer available."
            case .oversized: return "This window is larger than the display allows. Its title bar was kept on-screen."
            case .cancelled: return "The original app is no longer active. Reopen the HUD over that window."
            }
        }
    }
    static func close(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance &&
        abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }
    static func resizeFirst(current: CGRect, target: CGRect, area: CGRect) -> Bool {
        guard area.contains(current) else { return true }
        func overflow(_ rect: CGRect) -> CGFloat {
            max(0, area.minX - rect.minX) + max(0, rect.maxX - area.maxX) +
            max(0, area.minY - rect.minY) + max(0, rect.maxY - area.maxY)
        }
        return overflow(CGRect(origin: current.origin, size: target.size)) <=
            overflow(CGRect(origin: target.origin, size: current.size))
    }
    static func apply(requested: CGRect, area: CGRect, direction: SwipeDirection?, resizable: Bool, access: Access) -> Outcome {
        guard WindowTile.valid(requested), WindowTile.valid(area),
              let initial = access.read(), WindowTile.valid(initial) else { return .unavailable }
        guard access.isCurrent() else { return .cancelled }
        if close(initial, requested) { return .exact }
        var targetSize = requested.size
        if let minimum = access.minimum(), minimum.width.isFinite, minimum.height.isFinite,
           minimum.width >= 0, minimum.height >= 0 {
            targetSize.width = max(targetSize.width, min(minimum.width, area.width))
            targetSize.height = max(targetSize.height, min(minimum.height, area.height))
        }
        // Fixed-size windows are still movable. Do not resize an app that has
        // explicitly declared AXSize read-only.
        if !resizable { targetSize = initial.size }
        let target = WindowTile.aligned(targetSize, requested: requested, in: area, direction: direction)
        var previous: CGRect?
        var acceptedResize = false
        for attempt in 0..<4 {
            guard access.isCurrent() else { return .cancelled }
            guard let before = access.read(), WindowTile.valid(before) else { return .unavailable }
            let sizeFirst = resizeFirst(current: before, target: target, area: area)
            if resizable, sizeFirst { acceptedResize = access.resize(targetSize) || acceptedResize }
            guard access.isCurrent() else { return .cancelled }
            // A move can release a size restriction imposed by an old screen
            // edge; resize once more at the destination, then read back.
            guard let interim = access.read(), WindowTile.valid(interim) else { return .unavailable }
            let movingSize = resizable ? CGSize(width: max(interim.width, targetSize.width),
                height: max(interim.height, targetSize.height)) : interim.size
            let moveTo = WindowTile.aligned(movingSize, requested: requested, in: area, direction: direction)
            _ = access.move(moveTo.origin)
            if resizable {
                guard access.isCurrent() else { return .cancelled }
                acceptedResize = access.resize(targetSize) || acceptedResize
            }
            access.pause()
            guard access.isCurrent() else { return .cancelled }
            guard let actual = access.read(), WindowTile.valid(actual) else { return .unavailable }
            if close(actual, requested) { return .exact }
            let settled = WindowTile.aligned(actual.size, requested: requested, in: area, direction: direction)
            if !close(actual, settled) { _ = access.move(settled.origin) }
            access.pause()
            guard access.isCurrent() else { return .cancelled }
            guard let final = access.read(), WindowTile.valid(final) else { return .unavailable }
            if close(final, requested) { return .exact }
            // Do not mistake a toolkit's asynchronous, old size for a minimum.
            // Allow all settling passes before accepting a constrained result.
            if attempt == 3, close(final, settled), let previous, close(final, previous) {
                if final.width > area.width + 2 || final.height > area.height + 2 { return .oversized }
                if !resizable || acceptedResize || !close(final, initial) { return .constrained }
            }
            previous = final
        }
        return .failed
    }
}

@MainActor struct WindowTilingTarget {
    var isFullScreen: () -> Bool = { false }
    var command: (AppExplorerAction) -> String? = { _ in "This window command is unavailable." }
    // Returns a user-visible error, or nil on success. Injectable for HUD tests.
    var apply: (SwipeDirection, ExplorerWindowLayout) -> String?
}

@MainActor enum WindowTiling {
    struct AppWindow {
        var title: String
        var minimized: Bool
        var activate: () -> String?
    }
    /// Follow an existing application's window without moving it between Spaces.
    /// AX window enumeration includes windows that are not on the current desktop.
    static func focusApplicationWindow(pid: pid_t) {
        guard pid != ProcessInfo.processInfo.processIdentifier,
              let running = NSRunningApplication(processIdentifier: pid),
              !running.isTerminated else { return }
        guard AXIsProcessTrusted() else {
            _ = running.activate(options: [.activateAllWindows])
            return
        }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        func window(_ key: String) -> AXUIElement? {
            guard let value = attribute(app, key), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return unsafeBitCast(value, to: AXUIElement.self)
        }
        let windows = (attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []).filter {
            AXUIElementSetMessagingTimeout($0, 0.15)
            return (attribute($0, kAXRoleAttribute) as? String) == kAXWindowRole
        }
        let target = window(kAXFocusedWindowAttribute) ?? window(kAXMainWindowAttribute)
            ?? windows.first { (attribute($0, kAXMinimizedAttribute) as? Bool) != true } ?? windows.first
        guard let target else {
            _ = running.activate(options: [.activateAllWindows])
            return
        }
        AXUIElementSetMessagingTimeout(target, 0.15)
        if (attribute(target, kAXMinimizedAttribute) as? Bool) == true {
            _ = AXUIElementSetAttributeValue(target, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        _ = AXUIElementSetAttributeValue(target, kAXMainAttribute as CFString, kCFBooleanTrue)
        _ = running.activate(options: [.activateAllWindows])
        _ = AXUIElementSetAttributeValue(target, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        _ = AXUIElementPerformAction(target, kAXRaiseAction as CFString)
    }

    static func windows(pid: pid_t) -> [AppWindow] {
        guard AXIsProcessTrusted(), pid != ProcessInfo.processInfo.processIdentifier else { return [] }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        guard let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] else { return [] }
        return windows.compactMap { window in
            AXUIElementSetMessagingTimeout(window, 0.1)
            guard (attribute(window, kAXRoleAttribute) as? String) == kAXWindowRole else { return nil }
            let title = (attribute(window, kAXTitleAttribute) as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled window"
            return AppWindow(title: title, minimized: (attribute(window, kAXMinimizedAttribute) as? Bool) == true) {
                guard AXIsProcessTrusted(), let running = NSRunningApplication(processIdentifier: pid), !running.isTerminated else { return "The application is no longer available." }
                if (attribute(window, kAXMinimizedAttribute) as? Bool) == true {
                    guard AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse) == .success else { return "Could not restore this window." }
                }
                guard running.activate(options: []) else { return "Could not activate this application." }
                _ = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
                return AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success ? nil : "The window is no longer available or cannot be raised."
            }
        }
    }
    static func focusedWindowFrame(pid: pid_t) -> CGRect? {
        guard AXIsProcessTrusted(), pid != ProcessInfo.processInfo.processIdentifier else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.05)
        guard let value = attribute(app, kAXFocusedWindowAttribute) ?? attribute(app, kAXMainWindowAttribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let window = unsafeBitCast(value, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(window, 0.05)
        guard (attribute(window, kAXMinimizedAttribute) as? Bool) != true else { return nil }
        return frame(window)
    }

    static func capture(pid: pid_t) -> WindowTilingTarget? {
        guard AXIsProcessTrusted(), pid != ProcessInfo.processInfo.processIdentifier else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        guard let value = attribute(app, kAXFocusedWindowAttribute) ?? attribute(app, kAXMainWindowAttribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let window = unsafeBitCast(value, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(window, 0.2)
        var target = WindowTilingTarget { direction, layout in
            guard AXIsProcessTrusted() else { return "Enable Accessibility for Rotagivan, then try again." }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return "The original app is no longer active. Reopen Explorer over that window." }
            if (attribute(window, "AXFullScreen") as? Bool) == true { return "Exit full screen before tiling this window." }
            if (attribute(window, kAXMinimizedAttribute) as? Bool) == true { return "Restore the minimized window first." }
            guard let current = frame(window), let primary = NSScreen.screens.first else { return "The original window is no longer available." }
            let screens = NSScreen.screens
            let frames = screens.map { WindowTile.accessibilityFrame($0.frame, primaryTop: primary.frame.maxY) }
            guard let index = WindowTile.screenIndex(for: current, frames: frames) else { return "No display is available." }
            let area = WindowTile.accessibilityFrame(screens[index].visibleFrame.intersection(screens[index].frame), primaryTop: primary.frame.maxY)
            let desired = WindowTile.frame(direction, in: area, layout: layout, backingScale: screens[index].backingScaleFactor)
            return place(window, pid: pid, requested: desired, area: area, direction: direction)
        }
        target.isFullScreen = { (attribute(window, "AXFullScreen") as? Bool) == true }
        target.command = { command in
            guard AXIsProcessTrusted() else { return "Enable Accessibility for Rotagivan, then try again." }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return "The original app is no longer active. Reopen Explorer over that window." }
            let fullScreen = (attribute(window, "AXFullScreen") as? Bool) == true
            if fullScreen && command != .exitFullScreen && command != .toggleFullScreen { return "Exit full screen before using other window commands." }
            switch command {
            case .toggleFullScreen, .exitFullScreen:
                if command == .exitFullScreen && !fullScreen { return nil }
                let enabled = command == .toggleFullScreen && !fullScreen
                return AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, enabled ? kCFBooleanTrue : kCFBooleanFalse) == .success ? nil : "This app does not support changing full-screen mode."
            case .minimize:
                return AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue) == .success ? nil : "This window cannot be minimized."
            case .closeWindow:
                guard let value = attribute(window, kAXCloseButtonAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return "This window has no close button." }
                return AXUIElementPerformAction(unsafeBitCast(value, to: AXUIElement.self), kAXPressAction as CFString) == .success ? nil : "This window could not be closed."
            case .moveWindowPreviousDesktop, .moveWindowNextDesktop:
                return WindowDesktopTransfer.move(window: window, step: command == .moveWindowPreviousDesktop ? -1 : 1)
            case .maximize:
                guard let current = frame(window), let primary = NSScreen.screens.first else { return "The window is no longer available." }
                let screens = NSScreen.screens
                let frames = screens.map { WindowTile.accessibilityFrame($0.frame, primaryTop: primary.frame.maxY) }
                guard let index = WindowTile.screenIndex(for: current, frames: frames) else { return "No display is available." }
                let desired = WindowTile.accessibilityFrame(screens[index].visibleFrame.intersection(screens[index].frame), primaryTop: primary.frame.maxY)
                return place(window, pid: pid, requested: desired, area: desired, direction: nil)
            default: return "Unsupported window command."
            }
        }
        return target
    }

    private static func place(_ window: AXUIElement, pid: pid_t, requested: CGRect, area: CGRect, direction: SwipeDirection?) -> String? {
        if (attribute(window, "AXFullScreen") as? Bool) == true { return "Exit full screen before tiling this window." }
        if (attribute(window, kAXMinimizedAttribute) as? Bool) == true { return "Restore the minimized window first." }
        guard (attribute(window, kAXRoleAttribute) as? String) == kAXWindowRole else { return "Select an application window before tiling." }
        var movable: DarwinBoolean = false, resizable: DarwinBoolean = false
        let moveStatus = AXUIElementIsAttributeSettable(window, kAXPositionAttribute as CFString, &movable)
        let sizeStatus = AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &resizable)
        if moveStatus == .success, !movable.boolValue { return "This window does not support moving." }
        // macOS switches AXEnhancedUserInterface on in any app an Accessibility
        // client talks to. Chrome and Electron then animate frame changes and
        // report in-between geometry, so a read-back a few ms later sees the old
        // height and the next write snaps the window back (measured: a left-half
        // tile landed at the old 925 pt height with the flag on, exactly with it
        // off). Turn it off for the duration of the placement and restore it.
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        let enhanced = (attribute(app, "AXEnhancedUserInterface") as? Bool) == true
        if enhanced { _ = AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse) }
        defer { if enhanced { _ = AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) } }
        let access = WindowPlacement.Access(read: { frame(window) }, resize: { proposed in
            var size = proposed
            guard let value = AXValueCreate(.cgSize, &size) else { return false }
            return AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value) == .success
        }, move: { proposed in
            var point = proposed
            guard let value = AXValueCreate(.cgPoint, &point) else { return false }
            return AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value) == .success
        }, minimum: {
            for name in ["AXMinSize", "AXMinimumSize"] {
                guard let value = attribute(window, name), CFGetTypeID(value) == AXValueGetTypeID() else { continue }
                var size = CGSize.zero
                if AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cgSize, &size),
                   size.width.isFinite, size.height.isFinite, size.width >= 0, size.height >= 0 { return size }
            }
            return nil
        }, isCurrent: { NSWorkspace.shared.frontmostApplication?.processIdentifier == pid }, pause: {
            // Wait for the frame to stop changing rather than a fixed 25 ms, so an
            // app that applies geometry asynchronously is read after it settled.
            var last = frame(window)
            for _ in 0..<12 {
                Thread.sleep(forTimeInterval: 0.015)
                let next = frame(window)
                if let last, let next, WindowPlacement.close(last, next, tolerance: 0) { return }
                last = next
            }
        })
        return WindowPlacement.apply(requested: requested, area: area, direction: direction,
            resizable: sizeStatus != .success || resizable.boolValue, access: access).error
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

/// Wait for a successful activation and stable window geometry, without
/// stealing focus or jumping after the user has already moved the mouse.
@MainActor final class ExplorerCursorCentering {
    var frontmostPID: () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    var windowFrame: (pid_t) -> CGRect? = { WindowTiling.focusedWindowFrame(pid: $0) }
    var position: () -> CGPoint? = { CGEvent(source: nil)?.location }
    var move: (CGPoint) -> Void = { _ = CGWarpMouseCursorPosition($0) }
    var displays: () -> [CGRect] = {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { CGDisplayBounds($0) }
    }
    private var task: Task<Void, Never>?
    private let interval: UInt64
    private let attempts: Int

    init(interval: UInt64 = 50_000_000, attempts: Int = 40) {
        self.interval = interval
        self.attempts = attempts
    }

    func cancel() { task?.cancel(); task = nil }

    static func target(window: CGRect, displays: [CGRect]) -> CGPoint? {
        guard [window.minX, window.minY, window.width, window.height].allSatisfy(\.isFinite),
              window.width > 0, window.height > 0 else { return nil }
        let center = CGPoint(x: window.midX, y: window.midY)
        if displays.contains(where: { $0.contains(center) }) { return center }
        // A window may straddle a gap or extend off-screen. Pick the center
        // of its largest visible portion instead of warping into that gap.
        guard let visible = displays.map({ $0.intersection(window) })
            .filter({ !$0.isNull && !$0.isEmpty })
            .max(by: { $0.width * $0.height < $1.width * $1.height }) else { return nil }
        return CGPoint(x: visible.midX, y: visible.midY)
    }

    func start(pid: pid_t, origin: CGPoint?, isValid: @escaping () -> Bool) {
        cancel()
        guard let origin, origin.x.isFinite, origin.y.isFinite else { return }
        let previousPID = frontmostPID()
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            var lastFrame: CGRect?
            var targetWasActive = false
            for _ in 0..<attempts {
                do { try await Task.sleep(nanoseconds: interval) }
                catch { return }
                guard !Task.isCancelled, isValid(), let current = position(),
                      hypot(current.x - origin.x, current.y - origin.y) <= 3 else { return }
                let frontmost = frontmostPID()
                guard frontmost == pid else {
                    // Do not steal the cursor back from a third app, or from
                    // a user who switched away after the target became active.
                    if targetWasActive || frontmost != previousPID { return }
                    continue
                }
                targetWasActive = true
                guard let frame = windowFrame(pid) else { lastFrame = nil; continue }
                guard lastFrame == frame else { lastFrame = frame; continue }
                guard isValid(), frontmostPID() == pid,
                      let latest = position(), hypot(latest.x - origin.x, latest.y - origin.y) <= 3,
                      let point = Self.target(window: frame, displays: displays()) else { return }
                move(point)
                return
            }
        }
    }

    deinit { task?.cancel() }
}

struct WindowTileIcon: View {
    let direction: SwipeDirection
    var layout: ExplorerWindowLayout = .halves
    var accent: Color = .teal
    var body: some View {
        let area = CGRect(x: 0, y: 0, width: 42, height: 30)
        let tile = WindowTile.frame(direction, in: area, layout: layout).insetBy(dx: 2, dy: 2)
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4).strokeBorder(.secondary.opacity(0.5))
            RoundedRectangle(cornerRadius: 2).fill(accent).frame(width: tile.width, height: tile.height)
                .offset(x: tile.minX, y: tile.minY)
        }.frame(width: 42, height: 30).frame(height: 42).accessibilityHidden(true)
    }
}

// Private WindowServer functions are optional: fail closed on unsupported systems.
// Never alter Mission Control preferences or security protections.
@MainActor enum WindowDesktopTransfer {
    static func adjacent(to source: UInt64, step: Int, displays: [[UInt64]]) -> UInt64? {
        guard abs(step) == 1 else { return nil }
        for spaces in displays {
            if let index = spaces.firstIndex(of: source) {
                let next = index + step
                return spaces.indices.contains(next) ? spaces[next] : nil
            }
        }
        return nil
    }

    static func move(window: AXUIElement, step: Int) -> String? {
        typealias Connection = @convention(c) () -> Int32
        typealias WindowID = @convention(c) (AXUIElement, UnsafeMutablePointer<UInt32>) -> Int32
        typealias Displays = @convention(c) (Int32) -> Unmanaged<CFArray>?
        typealias Spaces = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
        typealias Move = @convention(c) (Int32, CFArray, UInt64) -> Void
        typealias Compatibility = @convention(c) (Int32, UInt64, Int32) -> Int32
        typealias Workspace = @convention(c) (Int32, UnsafeMutablePointer<UInt32>, Int32, Int32) -> Int32
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let ax = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY) else {
            return "Moving windows between desktops is unavailable on this macOS version."
        }
        defer { dlclose(handle); dlclose(ax) }
        func symbol<T>(_ name: String, _ type: T.Type) -> T? {
            guard let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: type)
        }
        guard let connection = symbol("SLSMainConnectionID", Connection.self),
              let displays = symbol("SLSCopyManagedDisplaySpaces", Displays.self),
              let spaces = symbol("SLSCopySpacesForWindows", Spaces.self),
              let axPointer = dlsym(ax, "_AXUIElementGetWindow") else {
            return "Moving windows between desktops is unsupported on this macOS version."
        }
        var windowID: UInt32 = 0
        let getWindow = unsafeBitCast(axPointer, to: WindowID.self)
        guard getWindow(window, &windowID) == 0, windowID != 0 else { return "Could not identify the focused window." }
        let cid = connection()
        let windows = [NSNumber(value: windowID)] as CFArray
        guard let membership = spaces(cid, 7, windows)?.takeRetainedValue() as? [NSNumber],
              membership.count == 1,
              let topology = displays(cid)?.takeRetainedValue() as? [[String: Any]] else {
            return "Only windows assigned to a single normal desktop can be moved."
        }
        let desktops: [[UInt64]] = topology.map { display in
            (display["Spaces"] as? [[String: Any]] ?? []).compactMap { space in
                guard (space["type"] as? NSNumber)?.intValue == 0 else { return nil }
                return (space["ManagedSpaceID"] as? NSNumber)?.uint64Value
            }
        }
        guard let destination = adjacent(to: membership[0].uint64Value, step: step, displays: desktops) else {
            return "There is no normal desktop in that direction on this display."
        }
        if #available(macOS 14.5, *) {
            guard let compat = symbol("SLSSpaceSetCompatID", Compatibility.self),
                  let workspace = symbol("SLSSetWindowListWorkspace", Workspace.self) else {
                return "This macOS version does not support moving this window."
            }
            let tag: Int32 = 0x726f7461
            guard compat(cid, destination, tag) == 0 else { return "macOS refused access to the destination desktop." }
            defer { _ = compat(cid, destination, 0) }
            guard workspace(cid, &windowID, 1, tag) == 0 else { return "macOS could not move this window." }
        } else {
            guard let move = symbol("SLSMoveWindowsToManagedSpace", Move.self) else { return "Moving windows is unsupported." }
            move(cid, windows, destination)
        }
        guard let result = spaces(cid, 7, windows)?.takeRetainedValue() as? [NSNumber],
              result.contains(where: { $0.uint64Value == destination }) else {
            return "macOS did not confirm the window move. This window or macOS version may not support it."
        }
        return nil
    }
}
