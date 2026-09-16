import AppKit
import CoreGraphics

final class EventPoster {
    private let source = CGEventSource(stateID: .hidSystemState)
    private let shortcutQueue = DispatchQueue(label: "local.rotagivan.shortcut-output")
    private(set) var dragging = false
    // CGEvent scrolling takes integral deltas. Keep the fractional remainder
    // so low-speed kinetic scrolling does not disappear between timer ticks.
    private var scrollRemainder = CGVector.zero
    // Cursor events have the same practical pixel granularity. Accumulating
    // sub-pixel fine movements lets a low Fine speed remain responsive.
    private var cursorRemainder = CGVector.zero

    static func tapKeyEvents(_ action: TapAction) -> [CGEvent] {
        guard action == .optionF19 || action == .enter else { return [] }
        return shortcutEvents(RecordedShortcut(keyCode: action == .optionF19 ? 80 : 36,
            modifiers: action == .optionF19 ? CGEventFlags.maskAlternate.rawValue : 0,
            keyLabel: action.title))
    }

    static func shortcutEvents(_ shortcut: RecordedShortcut, heldFlags: CGEventFlags = []) -> [CGEvent] {
        let allowed: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        let requested = CGEventFlags(rawValue: shortcut.modifiers).intersection(allowed)
        let modifiers: [(CGKeyCode, CGEventFlags)] = [(59, .maskControl), (58, .maskAlternate), (56, .maskShift), (55, .maskCommand)]
        let pressed = modifiers.filter { requested.contains($0.1) && !heldFlags.contains($0.1) }
        let eventSource = CGEventSource(stateID: .privateState)
        var flags = heldFlags.intersection(allowed)
        var events: [CGEvent] = []
        func append(_ key: CGKeyCode, down: Bool, modifier: Bool = false) -> Bool {
            guard let event = CGEvent(keyboardEventSource: eventSource, virtualKey: key, keyDown: down) else { return false }
            if modifier { event.type = .flagsChanged }
            event.flags = flags
            events.append(event)
            return true
        }
        for (key, flag) in pressed {
            flags.insert(flag)
            guard append(key, down: true, modifier: true) else { return [] }
        }
        guard append(shortcut.keyCode, down: true), append(shortcut.keyCode, down: false) else { return [] }
        for (key, flag) in pressed.reversed() {
            flags.remove(flag)
            guard append(key, down: false, modifier: true) else { return [] }
        }
        return events
    }

    private func postShortcut(_ shortcut: RecordedShortcut) {
        // Serialize complete chords so rapid taps cannot interleave their modifier releases.
        // Pace events off the main thread for listeners that track modifier transitions.
        shortcutQueue.async {
            let held = CGEventSource.flagsState(.hidSystemState)
            let events = Self.shortcutEvents(shortcut, heldFlags: held)
            for (index, event) in events.enumerated() {
                if index > 0 { Thread.sleep(forTimeInterval: event.type == .keyUp ? 0.04 : 0.012) }
                event.post(tap: .cghidEventTap)
            }
        }
    }

    func performTap(_ action: TapAction, shortcut: RecordedShortcut? = nil) {
        guard !dragging else { return }
        switch action {
        case .leftClick: click()
        case .rightClick: click(button: .right)
        case .none: break
        case .shortcut:
            if let shortcut { postShortcut(shortcut) }
        case .optionF19, .enter:
            postShortcut(RecordedShortcut(keyCode: action == .optionF19 ? 80 : 36,
                modifiers: action == .optionF19 ? CGEventFlags.maskAlternate.rawValue : 0,
                keyLabel: action.title))
        }
    }

    func move(dx: Double, dy: Double) {
        guard dx.isFinite, dy.isFinite, dx != 0 || dy != 0 else { return }
        let accumulatedX = dx + cursorRemainder.dx
        let accumulatedY = dy + cursorRemainder.dy
        let emittedX = accumulatedX.rounded(.towardZero)
        let emittedY = accumulatedY.rounded(.towardZero)
        cursorRemainder = CGVector(dx: accumulatedX - emittedX, dy: accumulatedY - emittedY)
        guard emittedX != 0 || emittedY != 0 else { return }
        let quartzCurrent = quartzMouseLocation()
        let target = constrained(CGPoint(x: quartzCurrent.x + emittedX, y: quartzCurrent.y + emittedY))
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
        let accumulatedX = dx + scrollRemainder.dx
        let accumulatedY = dy + scrollRemainder.dy
        let emittedX = accumulatedX.rounded(.towardZero)
        let emittedY = accumulatedY.rounded(.towardZero)
        scrollRemainder = CGVector(dx: accumulatedX - emittedX, dy: accumulatedY - emittedY)
        let sx = Int32(max(Double(Int32.min), min(Double(Int32.max), emittedX)))
        let sy = Int32(max(Double(Int32.min), min(Double(Int32.max), emittedY)))
        guard sx != 0 || sy != 0 else { return }
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: sy, wheel2: sx, wheel3: 0) else { return }
        // These are deliberately ordinary continuous scroll events. Synthetic
        // momentum-phase events are ignored by a number of macOS apps; the
        // timer itself provides the inertial motion.
        _ = momentum
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
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
