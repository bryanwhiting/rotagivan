// Read-only verification of the installed app's local YAML against its saved preferences.
import Foundation

@main struct InstalledSyncCheck {
    static func main() throws {
        let preferences = UserDefaults(suiteName: "local.rotagivan")!
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/rotagivan/settings.yaml")
        let actual = try AppConfiguration.parse(String(contentsOf: file, encoding: .utf8))
        var expected = actual
        expected.settings = try JSONDecoder().decode(StoredSettings.self, from: preferences.data(forKey: "settings.v1")!)
        func decode<T: Decodable>(_ type: T.Type, _ key: String, fallback: T) throws -> T {
            guard let data = preferences.data(forKey: key) else { return fallback }
            return try JSONDecoder().decode(type, from: data)
        }
        expected.shortcuts.normal = try decode(ProfileShortcut.self, "shortcut.normal", fallback: expected.shortcuts.normal)
        expected.shortcuts.precision = try decode(ProfileShortcut.self, "shortcut.precision", fallback: expected.shortcuts.precision)
        expected.shortcuts.additional = try decode([UInt32: ProfileShortcut].self, "shortcut.additional", fallback: [:])
        expected.shortcuts.profileActions = try decode([UInt32: [ProfileShortcut]].self, "shortcut.profileActions", fallback: [:])
        for index in 0..<3 {
            expected.shortcuts.actions[index] = try decode(ProfileShortcut.self, "shortcut.action.\(index + 3)", fallback: expected.shortcuts.actions[index])
        }
        expected.shortcuts.holdToActivate = preferences.object(forKey: "shortcut.hold") as? Bool ?? true
        let equal = try expected.syncFingerprint() == actual.syncFingerprint()
        precondition(equal, "Installed YAML differs from saved profiles/shortcuts")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        precondition((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        print("Installed local YAML is valid, owner-only, and matches all saved profiles and shortcuts.")
    }
}
