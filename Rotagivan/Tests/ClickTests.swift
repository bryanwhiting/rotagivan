import CoreGraphics

@main
struct ClickTests {
    static func main() {
        let point = CGPoint(x: 120, y: 240)
        let single = EventPoster.clickEvents(position: point, count: 1)
        precondition(single.map(\.type) == [.leftMouseDown, .leftMouseUp])
        let double = EventPoster.clickEvents(position: point, count: 2)
        precondition(double.map(\.type) == [.leftMouseDown, .leftMouseUp, .leftMouseDown, .leftMouseUp])
        precondition(double.map { $0.getIntegerValueField(.mouseEventClickState) } == [1, 1, 2, 2])
        precondition(double.allSatisfy { $0.location == point })
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
