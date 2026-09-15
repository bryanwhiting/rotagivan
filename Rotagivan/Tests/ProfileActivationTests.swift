import Foundation

@main
struct ProfileActivationTests {
    @MainActor static func main() throws {
        let defaults = [ProfileShortcut(keyCode: 79), ProfileShortcut(keyCode: 80), ProfileShortcut(keyCode: 90)]
        let primary = [ProfileShortcut(keyCode: 0, modifiers: 256, enabled: true), defaults[1], defaults[2]]
        let custom = [ProfileShortcut(keyCode: 1, modifiers: 256, enabled: true), defaults[0], ProfileShortcut(keyCode: 64)]
        let inherited = HotKeyManager.resolvedActions(for: 100, defaults: defaults, saved: [1: primary, 100: custom], customTapProfiles: [])
        precondition(inherited == [primary[0], primary[1], custom[2]])
        precondition(HotKeyManager.resolvedActions(for: 100, defaults: defaults, saved: [1: primary, 100: custom], customTapProfiles: [100]) == custom)
        precondition(HotKeyManager.resolvedActions(for: 1, defaults: defaults, saved: [1: primary], customTapProfiles: []) == primary)
        print("Click shortcut inheritance passed; drag shortcuts remain profile-specific.")
        let legacy = try JSONDecoder().decode(ProfileShortcut.self, from: Data("{\"keyCode\":64,\"modifiers\":0,\"enabled\":true}".utf8))
        precondition(legacy.holdToActivate == nil)
        var state = ProfileActivationState()
        precondition(state.active == 1)
        precondition(state.handle(id: 2, down: true, hold: false) == 2)
        precondition(state.handle(id: 2, down: true, hold: false) == 2) // Ignore repeats.
        precondition(state.handle(id: 2, down: false, hold: false) == 2)
        precondition(state.handle(id: 1, down: true, hold: true) == 1)
        precondition(state.handle(id: 1, down: false, hold: true) == 2) // Restore latched profile.
        precondition(state.handle(id: 2, down: true, hold: false) == 1)
        precondition(state.handle(id: 2, down: false, hold: false) == 1)
        precondition(state.handle(id: 1, down: true, hold: false) == 2) // Normal toggles too.
        precondition(state.handle(id: 1, down: false, hold: false) == 2)
        state = ProfileActivationState()
        precondition(state.handle(id: 2, down: true, hold: true) == 2)
        precondition(state.handle(id: 1, down: true, hold: true) == 1)
        precondition(state.handle(id: 1, down: false, hold: true) == 2)
        precondition(state.handle(id: 2, down: false, hold: true) == 1)
        precondition(state.handle(id: 100, down: true, hold: false) == 100)
        precondition(state.handle(id: 100, down: false, hold: false) == 100)
        precondition(state.handle(id: 101, down: true, hold: true) == 101)
        precondition(state.handle(id: 101, down: false, hold: true) == 100)
        precondition(state.handle(id: 2, down: true, hold: false) == 2)
        precondition(state.handle(id: 2, down: false, hold: false) == 2)
        precondition(state.handle(id: 2, down: true, hold: false) == 100)
        precondition(state.handle(id: 2, down: false, hold: false) == 100)
        print("Profile activation tests passed: legacy decoding, toggles, repeat suppression, mixed modes, overlapping holds.")
        state = ProfileActivationState(defaultID: 100)
        precondition(state.active == 100)
        precondition(state.handle(id: 1, down: true, hold: true) == 1)
        precondition(state.handle(id: 1, down: false, hold: true) == 100)
        precondition(state.handle(id: 2, down: true, hold: false) == 2)
        precondition(state.handle(id: 2, down: false, hold: false) == 2)
        precondition(state.handle(id: 2, down: true, hold: false) == 100)
        let newDefaultActions = HotKeyManager.resolvedActions(for: 2, defaults: defaults, saved: [100: custom], customTapProfiles: [], defaultID: 100)
        precondition(newDefaultActions == [custom[0], custom[1], defaults[2]])
        print("Selectable default passed: initial activation, hold release, tap toggle, inherited shortcuts.")
    }
}
