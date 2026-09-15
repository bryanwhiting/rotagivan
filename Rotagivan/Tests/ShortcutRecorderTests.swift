import AppKit

@main
struct ShortcutRecorderTests {
    @MainActor static func main() throws {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.option, .capsLock, .function], timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 80)!
        let shortcut = RecordedShortcut.capture(event)
        precondition(shortcut.keyCode == 80)
        precondition(shortcut.modifiers == UInt64(NSEvent.ModifierFlags.option.rawValue))
        precondition(shortcut.displayName == "⌥F19")
        let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        precondition(RecordedShortcut.capture(enter).displayName == "Return")
        var profile = ProfileShortcut(holdToActivate: false)
        profile.assign(shortcut)
        precondition(profile.keyCode == 80 && profile.modifiers == 2048)
        precondition(profile.enabled && profile.holdToActivate == false)
        precondition(profile.displayName == "⌥F19")
        profile.assign(RecordedShortcut(keyCode: 0, modifiers: UInt64(NSEvent.ModifierFlags([.command, .control, .shift, .option]).rawValue), keyLabel: "A"))
        precondition(profile.modifiers == 6912)
        precondition(profile.displayName == "⌃⌥⇧⌘A")
        let restored = try JSONDecoder().decode(ProfileShortcut.self, from: JSONEncoder().encode(profile))
        precondition(restored == profile)
        print("Profile recorder passed: Carbon modifier conversion, enable on capture, preserved activation mode, persistence.")
        print("Shortcut capture passed: function keys, modifiers, plain Return, ignored Caps Lock/Fn flags.")
    }
}
