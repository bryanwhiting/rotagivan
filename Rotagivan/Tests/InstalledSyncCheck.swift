// Read-only validation of an optional manually saved YAML snapshot.
import Foundation

@main struct InstalledSyncCheck {
    static func main() throws {
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/rotagivan/settings.yaml")
        guard FileManager.default.fileExists(atPath: file.path) else {
            print("No settings.yaml snapshot yet. Manual sync creates it only when Save is pressed.")
            return
        }
        _ = try AppConfiguration.parse(String(contentsOf: file, encoding: .utf8))
        // In manual mode, saved YAML may intentionally differ from live preferences.
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        precondition((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        print("Installed local YAML is valid and owner-only. Live settings may differ until the next manual Save.")
    }
}
