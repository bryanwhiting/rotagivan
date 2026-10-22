import Foundation

@main struct MacroAuditTests {
    static func main() {
        let key = RecordedShortcut(keyCode: 64, modifiers: 1 << 20, keyLabel: "F17")
        let macro = NamedHotkey(name: "Sequence", shortcut: key, steps: [key, key])
        var settings = StoredSettings()
        settings.hotkeyDictionary = [macro]; settings.appOverrides = []
        let first = ExplorerHoldLayer(name: "First", holdShortcut: nil, launchShortcut: key, appBundleID: "app.first")
        let second = ExplorerHoldLayer(name: "Second", holdShortcut: nil, launchShortcut: key, appBundleID: "app.second")
        settings.appExplorer = AppExplorerSettings(holdLayers: [first, second])
        var keys = ShortcutConfiguration(); keys.precision.enabled = false
        func audit() -> HotkeyAudit { HotkeyAudit(settings: settings, shortcuts: keys, layerID: 1, device: .navigator) }
        precondition(audit().findings.contains { $0.kind == .conflict }, "Legacy app metadata cannot hide a global launcher conflict")
        var taps = settings.gestures(for: 1)
        taps.gestures.tapToClick = true; taps.oneFingerTap = .shortcut; taps.oneFingerShortcut = .macro(macro)
        settings.profileGestures = [1: taps]
        precondition(audit().assignments.filter { $0.id.hasPrefix("global.oneFingerTap.step.") }.count == 2)
        precondition(audit().findings.contains { $0.id.hasPrefix("interception.") }, "Macro steps must be checked against registered launch keys")
        settings.hotkeyDictionary = []
        precondition(audit().findings.contains { $0.title == "Missing macro" })
        taps.oneFingerShortcut = .hudLayer(first); settings.profileGestures = [1: taps]
        settings.appExplorer = nil
        precondition(audit().findings.contains { $0.title == "Missing HUD layer" })
        print("Macro audit passed: per-step interception, missing targets, and global HUD launcher conflicts")
    }
}
