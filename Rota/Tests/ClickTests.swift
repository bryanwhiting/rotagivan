import CoreGraphics

@main
struct ClickTests {
    static func main() {
        let point = CGPoint(x: 120, y: 240)
        var sequence = EventPoster.ClickSequence()
        func tap(_ time: Double, at location: CGPoint = CGPoint(x: 120, y: 240),
                 button: CGMouseButton = .left, count: Int = 1,
                 target: Int32 = 1, flags: CGEventFlags = []) -> [Int64] {
            sequence.events(position: location, button: button, count: count, at: time,
                interval: 0.5, target: target, flags: flags)
                .map { $0.getIntegerValueField(.mouseEventClickState) }
        }
        precondition(tap(0) == [1, 1])
        precondition(tap(0.15) == [2, 2])
        precondition(tap(0.3) == [3, 3], "Three ordinary taps must select a paragraph, not send three single clicks")
        precondition(tap(0.4) == [1, 1])
        precondition(tap(1) == [1, 1], "Slow taps are independent")
        precondition(tap(1.1, at: CGPoint(x: 140, y: 240)) == [1, 1], "Clicks elsewhere are independent")
        precondition(tap(1.2, at: CGPoint(x: 140, y: 240), target: 2) == [1, 1])
        precondition(tap(1.3, at: CGPoint(x: 140, y: 240), target: 2, flags: .maskShift) == [1, 1])
        precondition(tap(1.4, at: CGPoint(x: 140, y: 240), button: .right, target: 2, flags: .maskShift) == [1, 1])
        sequence.reset()
        precondition(tap(2, count: 2) == [1, 1, 2, 2])
        precondition(tap(2.1) == [3, 3], "An explicit double-click followed by a plain tap must reach three")
        precondition(tap(2.2, count: 3) == [1, 1, 2, 2, 3, 3], "Explicit triple-click actions remain self-contained")
        sequence.reset()
        precondition(tap(2.3) == [1, 1])
        print("Ordinary tap sequences, native multi-click counts, timeout, position, context, and explicit actions passed.")
        let single = EventPoster.clickEvents(position: point, count: 1)
        precondition(single.map(\.type) == [.leftMouseDown, .leftMouseUp])
        let double = EventPoster.clickEvents(position: point, count: 2)
        precondition(double.map(\.type) == [.leftMouseDown, .leftMouseUp, .leftMouseDown, .leftMouseUp])
        precondition(double.map { $0.getIntegerValueField(.mouseEventClickState) } == [1, 1, 2, 2])
        precondition(double.allSatisfy { $0.getIntegerValueField(.mouseEventButtonNumber) == Int64(CGMouseButton.left.rawValue) })
        precondition(double.allSatisfy { $0.location == point })
        let triple = EventPoster.clickEvents(position: point, count: 3)
        precondition(triple.map(\.type) == [.leftMouseDown, .leftMouseUp, .leftMouseDown, .leftMouseUp, .leftMouseDown, .leftMouseUp])
        precondition(triple.map { $0.getIntegerValueField(.mouseEventClickState) } == [1, 1, 2, 2, 3, 3])
        precondition(triple.allSatisfy { $0.location == point && $0.getIntegerValueField(.mouseEventButtonNumber) == 0 })
        precondition(EventPoster.tapKeyEvents(.tripleLeftClick).isEmpty)
        print("Native triple-click event ordering, click count, and fixed position passed (no events posted).")
        for (action, key, flags) in [(TapAction.optionF19, Int64(80), CGEventFlags.maskAlternate), (.enter, Int64(36), CGEventFlags())] {
            let events = EventPoster.tapKeyEvents(action).filter { $0.type != .flagsChanged }
            precondition(events.map(\.type) == [.keyDown, .keyUp])
            precondition(events.allSatisfy { $0.getIntegerValueField(.keyboardEventKeycode) == key && $0.flags == flags })
        }
        precondition(EventPoster.tapKeyEvents(.none).isEmpty)
        let recorded = RecordedShortcut(keyCode: 0, modifiers: CGEventFlags([.maskCommand, .maskShift]).rawValue, keyLabel: "A")
        let customEvents = EventPoster.shortcutEvents(recorded).filter { $0.type != .flagsChanged }
        precondition(customEvents.map(\.type) == [.keyDown, .keyUp])
        precondition(customEvents.allSatisfy { $0.getIntegerValueField(.keyboardEventKeycode) == 0 && $0.flags == [.maskCommand, .maskShift] })
        let plainEnter = EventPoster.shortcutEvents(RecordedShortcut(keyCode: 36, modifiers: 0, keyLabel: "Return"))
        precondition(plainEnter.allSatisfy { $0.flags.isEmpty && $0.getIntegerValueField(.keyboardEventKeycode) == 36 })
        print("Recorded shortcut event tests passed (no events posted).")
        let flowShortcut = RecordedShortcut(keyCode: 64, modifiers: CGEventFlags([.maskCommand, .maskAlternate]).rawValue, keyLabel: "F17")
        let flowEvents = EventPoster.shortcutEvents(flowShortcut)
        precondition(flowEvents.map(\.type) == [.flagsChanged, .flagsChanged, .keyDown, .keyUp, .flagsChanged, .flagsChanged])
        precondition(flowEvents.map { $0.getIntegerValueField(.keyboardEventKeycode) } == [58, 55, 64, 64, 55, 58])
        precondition(flowEvents.map(\.flags) == [.maskAlternate, [.maskAlternate, .maskCommand], [.maskAlternate, .maskCommand], [.maskAlternate, .maskCommand], .maskAlternate, []])
        let heldOption = EventPoster.shortcutEvents(flowShortcut, heldFlags: .maskAlternate)
        precondition(heldOption.map { $0.getIntegerValueField(.keyboardEventKeycode) } == [55, 64, 64, 55])
        precondition(heldOption.last?.flags == .maskAlternate)
        let alreadyHeld = EventPoster.shortcutEvents(flowShortcut, heldFlags: [.maskCommand, .maskAlternate])
        precondition(alreadyHeld.map(\.type) == [.keyDown, .keyUp])
        print("Command + Option + F17 event generation passed (Wispr Flow was not triggered).")
        print("Tap shortcut key codes, modifiers and release checks passed.")
        print("Single/double click event ordering, count and position checks passed (no events posted).")
    }
}
