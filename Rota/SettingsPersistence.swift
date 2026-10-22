import os
import AppKit
import CryptoKit
import Security

/// Production installs configure this before constructing preference consumers.
/// Tests keep their injected defaults and never touch the login Keychain.
enum SettingsPersistence {
    static var defaults: UserDefaults = .standard
    static var encrypted: EncryptedPreferences?
    static let applicationSupport = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Rota", isDirectory: true)
    static let directory = applicationSupport.appendingPathComponent("Settings", isDirectory: true)
    static let keychainService = "local.rota.settings.v1"
    /// Where the app kept everything while it was named Rotagivan. Existing
    /// installs are carried forward once; nothing is deleted or re-encrypted.
    static let legacyApplicationSupport = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Rotagivan", isDirectory: true)
    static let legacyKeychainService = "local.rotagivan.settings.v1"
    static let legacyBundleIdentifier = "local.rotagivan"

    /// The 32-byte key that seals the local settings database, by Keychain service.
    struct KeyStore {
        var read: (_ service: String, _ allowInteraction: Bool) throws -> Data?
        var add: (_ key: Data, _ service: String) throws -> Void
        static let keychain = KeyStore(read: readKey(service:allowInteraction:), add: addKey(_:service:))
    }

    @MainActor static func bootstrap() {
        var interactive = false
        while true {
            do {
                try migrateLegacyInstall(allowInteraction: interactive)
                let url = directory.appendingPathComponent("settings.sqlite")
                let key = try localKey(allowInteraction: interactive, existing: FileManager.default.fileExists(atPath: url.path))
                let database = try EncryptedSettingsDatabase(url: url, master: key, scope: "local-preferences")
                let adapter = try EncryptedPreferences(database: database)
                if !adapter.bool(forKey: "encrypted.migrated.v1") {
                    var legacy = legacyPlaintextPreferences()
                    legacy["encrypted.migrated.v1"] = true
                    try adapter.importLegacySynchronously(legacy)
                    // Verify a fresh authenticated read before retiring plaintext preferences.
                    _ = try EncryptedPreferences(database: EncryptedSettingsDatabase(url: url, master: key, scope: "local-preferences"))
                    retireLegacyPlaintextPreferences()
                }
                // Remove only managed private configuration, never OS preferences.
                for key in UserDefaults.standard.dictionaryRepresentation().keys where sensitive(key) {
                    UserDefaults.standard.removeObject(forKey: key)
                }
                // Local-file sync keeps a plaintext settings.yaml on purpose.
                if adapter.string(forKey: SyncSecrets.modeKey) != SyncMode.local.rawValue { try migrateManagedFiles(key: key) }
                defaults = adapter; encrypted = adapter
                SyncSecrets.defaults = { adapter }
                return
            } catch {
                Logger(subsystem: "local.rota", category: "settings")
                    .error("Settings bootstrap failed (interactive: \(interactive)): \(String(describing: error), privacy: .public)")
                let alert = NSAlert()
                alert.messageText = "Unlock your saved settings"
                alert.informativeText = "Rota could not open its encrypted settings. Unlock your login Keychain, allow access if macOS asks, and retry. Your saved data will not be replaced."
                alert.addButton(withTitle: "Unlock & retry")
                alert.addButton(withTitle: "Quit")
                if alert.runModal() != .alertFirstButtonReturn { exit(0) }
                interactive = true
            }
        }
    }
    /// Plaintext preferences written before encrypted storage, under the current
    /// bundle identifier and under the one the app had as Rotagivan.
    static func legacyPlaintextPreferences() -> [String: Any] {
        var merged = UserDefaults.standard.persistentDomain(forName: legacyBundleIdentifier) ?? [:]
        if let current = Bundle.main.bundleIdentifier, current != legacyBundleIdentifier {
            merged.merge(UserDefaults.standard.persistentDomain(forName: current) ?? [:]) { _, current in current }
        }
        return merged
    }
    /// After the import is verified, strip managed private configuration from the
    /// old plaintext domain as well; the current domain is swept on every launch.
    private static func retireLegacyPlaintextPreferences() {
        guard Bundle.main.bundleIdentifier != legacyBundleIdentifier,
              var domain = UserDefaults.standard.persistentDomain(forName: legacyBundleIdentifier) else { return }
        let keys = domain.keys.filter(sensitive)
        guard !keys.isEmpty else { return }
        for key in keys { domain.removeValue(forKey: key) }
        UserDefaults.standard.setPersistentDomain(domain, forName: legacyBundleIdentifier)
    }
    private static func sensitive(_ key: String) -> Bool {
        key == "settings.v1" || key == "configurationProfiles.v1" || key.hasPrefix("shortcut.") || key.hasPrefix("configuration.")
    }
    /// Carry an existing Rotagivan install forward: copy its database key to the
    /// new Keychain service and move its Application Support folder. Each step is
    /// skipped when the new location already exists, so both copies are kept and
    /// a partially completed migration finishes on the next launch.
    static func migrateLegacyInstall(allowInteraction: Bool, keys: KeyStore = .keychain,
                                     legacyService: String = legacyKeychainService, service: String = keychainService,
                                     legacyFolder: URL = legacyApplicationSupport, folder: URL = applicationSupport) throws {
        if try keys.read(service, allowInteraction) == nil {
            // The old item trusts only the Rotagivan signature, so macOS has to ask
            // once before Rota may read it. The copy is saved under Rota's own
            // signature and is read silently from then on.
            if let key = try keys.read(legacyService, true) { try keys.add(key, service) }
        }
        try moveLegacyDirectory(from: legacyFolder, to: folder)
    }
    /// Moves `legacy` to `current` when `current` is absent. When only the settings
    /// database is missing from an existing `current`, just that subfolder moves.
    static func moveLegacyDirectory(from legacy: URL, to current: URL) throws {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: legacy.path, isDirectory: &isDirectory), isDirectory.boolValue else { return }
        if !fm.fileExists(atPath: current.path) {
            try fm.createDirectory(at: current.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: legacy, to: current)
            return
        }
        let legacySettings = legacy.appendingPathComponent("Settings", isDirectory: true)
        let settings = current.appendingPathComponent("Settings", isDirectory: true)
        guard fm.fileExists(atPath: legacySettings.path, isDirectory: &isDirectory), isDirectory.boolValue,
              !fm.fileExists(atPath: settings.path) else { return }
        try fm.moveItem(at: legacySettings, to: settings)
    }
    /// Retire app-managed plaintext snapshots only after an authenticated,
    /// recoverable encrypted copy has been written. User exports are untouched.
    static func migrateManagedFiles(key: Data, root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/rota")) throws {
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
    private static func query(service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: "device",
         kSecAttrSynchronizable as String: false]
    }
    /// nil when no item exists; throws when the Keychain refuses (locked, or an
    /// item saved under the Rotagivan signature that needs the user's approval).
    private static func readKey(service: String, allowInteraction: Bool) throws -> Data? {
        var read = query(service: service)
        read[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = try CredentialKeychainRead.copy(read, result: &result, allowInteraction: allowInteraction)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, data.count == 32 else { throw EncryptedSettingsError.invalidEnvelope }
        return data
    }
    private static func addKey(_ key: Data, service: String) throws {
        var insert = query(service: service)
        insert[kSecValueData as String] = key
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else { throw EncryptedSettingsError.databaseFailure }
    }
    private static func localKey(allowInteraction: Bool, existing: Bool) throws -> Data {
        if let key = try readKey(service: keychainService, allowInteraction: allowInteraction) { return key }
        guard !existing else { throw EncryptedSettingsError.invalidEnvelope }
        let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        try addKey(key, service: keychainService)
        return key
    }
}
