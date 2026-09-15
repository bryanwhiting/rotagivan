import AppKit
import CoreGraphics

final class EventPoster {
    private let source = CGEventSource(stateID: .hidSystemState)
    private(set) var dragging = false

    static func tapKeyEvents(_ action: TapAction) -> [CGEvent] {
        guard action == .optionF19 || action == .enter else { return [] }
        let key: CGKeyCode = action == .optionF19 ? 80 : 36
        return [true, false].compactMap { down in
            let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down)
            event?.flags = action == .optionF19 ? .maskAlternate : []
            return event
        }
    }

    func performTap(_ action: TapAction) {
        guard !dragging else { return }
        switch action {
        case .leftClick: click()
        case .rightClick: click(button: .right)
        case .none: break
        case .optionF19, .enter:
            Self.tapKeyEvents(action).forEach { $0.post(tap: .cghidEventTap) }
        }
    }

    func move(dx: Double, dy: Double) {
        guard dx.isFinite, dy.isFinite, dx != 0 || dy != 0 else { return }
        let quartzCurrent = quartzMouseLocation()
        let target = constrained(CGPoint(x: quartzCurrent.x + dx, y: quartzCurrent.y + dy))
        let type: CGEventType = (dragging || CGEventSource.buttonState(.combinedSessionState, button: .left)) ? .leftMouseDragged : .mouseMoved
        CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: target, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    func click(button: CGMouseButton = .left, count: Int = 1) {
        guard !dragging else { return }
        let position = quartzMouseLocation()
        Self.clickEvents(position: position, button: button, count: count).forEach { $0.post(tap: .cghidEventTap) }
    }

    static func clickEvents(position: CGPoint, button: CGMouseButton = .left, count: Int) -> [CGEvent] {
        var events: [CGEvent] = []
        let down: CGEventType = button == .right ? .rightMouseDown : .leftMouseDown
        let up: CGEventType = button == .right ? .rightMouseUp : .leftMouseUp
        for click in 1...max(1, min(2, count)) {
            for type in [down, up] {
                let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: position, mouseButton: button)
                event?.setIntegerValueField(.mouseEventClickState, value: Int64(click))
                if let event { events.append(event) }
            }
        }
        return events
    }

    func beginDrag() {
        guard !dragging else { return }
        dragging = true
        CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: quartzMouseLocation(), mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    func endDrag() {
        guard dragging else { return }
        dragging = false
        CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: quartzMouseLocation(), mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    func scroll(dx: Double, dy: Double, momentum: Bool = false) {
        guard dx.isFinite, dy.isFinite else { return }
        let sx = Int32(max(Double(Int32.min), min(Double(Int32.max), dx.rounded())))
        let sy = Int32(max(Double(Int32.min), min(Double(Int32.max), dy.rounded())))
        guard sx != 0 || sy != 0 else { return }
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: sy, wheel2: sx, wheel3: 0) else { return }
        if momentum { event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 2) }
        event.post(tap: .cghidEventTap)
    }

    private func quartzMouseLocation() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    private func constrained(_ point: CGPoint) -> CGPoint {
        for screen in NSScreen.screens {
            let frame = Self.quartzFrame(screen.frame)
            if frame.contains(point) { return point }
        }
        return NSScreen.screens
            .map { Self.quartzFrame($0.frame) }
            .map { frame in CGPoint(x: max(frame.minX, min(frame.maxX - 1, point.x)), y: max(frame.minY, min(frame.maxY - 1, point.y))) }
            .min(by: { hypot($0.x - point.x, $0.y - point.y) < hypot($1.x - point.x, $1.y - point.y) }) ?? point
    }

    private static var desktopHeight: CGFloat {
        NSScreen.screens.first?.frame.maxY ?? 0
    }

    private static func quartzFrame(_ frame: CGRect) -> CGRect {
        CGRect(x: frame.minX, y: desktopHeight - frame.maxY, width: frame.width, height: frame.height)
    }
}
