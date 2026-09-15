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
            let events = EventPoster.tapKeyEvents(action)
            precondition(events.map(\.type) == [.keyDown, .keyUp])
            precondition(events.allSatisfy { $0.getIntegerValueField(.keyboardEventKeycode) == key && $0.flags == flags })
        }
        precondition(EventPoster.tapKeyEvents(.none).isEmpty)
        print("Tap shortcut key codes, modifiers and release checks passed.")
        print("Single/double click event ordering, count and position checks passed (no events posted).")
    }
}
