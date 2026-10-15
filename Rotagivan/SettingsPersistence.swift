import AppKit
import CryptoKit
import Security

/// Production installs configure this before constructing preference consumers.
/// Tests keep their injected defaults and never touch the login Keychain.
enum SettingsPersistence {
    static var defaults: UserDefaults = .standard
    static var encrypted: EncryptedPreferences?
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Rotagivan/Settings", isDirectory: true)

    @MainActor static func bootstrap() {
        var interactive = false
        while true {
            do {
                let url = directory.appendingPathComponent("settings.sqlite")
                let key = try localKey(allowInteraction: interactive, existing: FileManager.default.fileExists(atPath: url.path))
                let database = try EncryptedSettingsDatabase(url: url, master: key, scope: "local-preferences")
                let adapter = try EncryptedPreferences(database: database)
                if !adapter.bool(forKey: "encrypted.migrated.v1") {
                    var legacy = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "local.rotagivan") ?? [:]
                    legacy["encrypted.migrated.v1"] = true
                    try adapter.importLegacySynchronously(legacy)
                    // Verify a fresh authenticated read before retiring plaintext preferences.
                    _ = try EncryptedPreferences(database: EncryptedSettingsDatabase(url: url, master: key, scope: "local-preferences"))
                }
                // Remove only managed private configuration, never OS preferences.
                for key in UserDefaults.standard.dictionaryRepresentation().keys where sensitive(key) {
                    UserDefaults.standard.removeObject(forKey: key)
                }
                try migrateManagedFiles(key: key)
                defaults = adapter; encrypted = adapter
                return
            } catch {
                let alert = NSAlert()
                alert.messageText = "Unlock your saved settings"
                alert.informativeText = "Rotagivan could not open its encrypted settings. Unlock your login Keychain and retry. Your saved data will not be replaced."
                alert.addButton(withTitle: "Unlock & retry")
                alert.addButton(withTitle: "Quit")
                if alert.runModal() != .alertFirstButtonReturn { exit(0) }
                interactive = true
            }
        }
    }
    private static func sensitive(_ key: String) -> Bool {
        key == "settings.v1" || key == "configurationProfiles.v1" || key.hasPrefix("shortcut.") || key.hasPrefix("configuration.")
    }
    /// Retire app-managed plaintext snapshots only after an authenticated,
    /// recoverable encrypted copy has been written. User exports are untouched.
    static func migrateManagedFiles(key: Data, root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/rotagivan")) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return }
        guard try fm.attributesOfItem(atPath: root.path)[.type] as? FileAttributeType == .typeDirectory else { throw EncryptedSettingsError.unsafePath }
        var files = [root.appendingPathComponent("settings.yaml")]
        let backup = root.appendingPathComponent("backup")
        if fm.fileExists(atPath: backup.path) {
            guard try fm.attributesOfItem(atPath: backup.path)[.type] as? FileAttributeType == .typeDirectory else { throw EncryptedSettingsError.unsafePath }
            files += try fm.contentsOfDirectory(at: backup, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("settings-") && $0.pathExtension == "yaml" }
        }
        for file in files where fm.fileExists(atPath: file.path) {
            let attrs = try fm.attributesOfItem(atPath: file.path)
            guard attrs[.type] as? FileAttributeType == .typeRegular,
                  (attrs[.size] as? NSNumber)?.intValue ?? Int.max <= 1_048_576 else { throw EncryptedSettingsError.unsafePath }
            let source = try Data(contentsOf: file)
            let encrypted = file.appendingPathExtension("encrypted")
            let envelope = try SettingsCipherEnvelope.seal(source, master: key, scope: "legacy-snapshots", purpose: file.lastPathComponent, revision: 1)
            if !fm.fileExists(atPath: encrypted.path) {
                try JSONEncoder().encode(envelope).write(to: encrypted, options: .withoutOverwriting)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: encrypted.path)
            }
            guard try fm.attributesOfItem(atPath: encrypted.path)[.type] as? FileAttributeType == .typeRegular else { throw EncryptedSettingsError.unsafePath }
            let verified = try JSONDecoder().decode(SettingsCipherEnvelope.self, from: Data(contentsOf: encrypted))
                .open(master: key, scope: "legacy-snapshots", purpose: file.lastPathComponent)
            guard verified == source else { throw EncryptedSettingsError.invalidEnvelope }
            try fm.removeItem(at: file)
        }
    }
    private static func localKey(allowInteraction: Bool, existing: Bool) throws -> Data {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "local.rotagivan.settings.v1", kSecAttrAccount as String: "device",
            kSecAttrSynchronizable as String: false]
        var read = query
        read[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = try CredentialKeychainRead.copy(read, result: &result, allowInteraction: allowInteraction)
        if status == errSecSuccess, let data = result as? Data, data.count == 32 { return data }
        guard status == errSecItemNotFound, !existing else { throw EncryptedSettingsError.invalidEnvelope }
        let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        var insert = query
        insert[kSecValueData as String] = key
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else { throw EncryptedSettingsError.databaseFailure }
        return key
    }
}
