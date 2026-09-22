import CryptoKit
import Foundation
import Security

struct SyncAccount: Codable, Equatable {
    var token: String
    var userID: String
    var email: String
    var expiresAt: Double
}

enum SyncKeychain {
    private static func query(_ server: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "local.rotagivan.sync",
         kSecAttrAccount as String: server]
    }
    static func read(server: String) throws -> SyncAccount? {
        var request = query(server)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw ConfigurationError("Keychain could not read the saved login (\(status)).")
        }
        return try JSONDecoder().decode(SyncAccount.self, from: data)
    }
    static func save(_ account: SyncAccount, server: String) throws {
        let data = try JSONEncoder().encode(account)
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query(server) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query(server).merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw ConfigurationError("Keychain could not save the login (\(status)).") }
    }
    static func remove(server: String) throws {
        let status = SecItemDelete(query(server) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ConfigurationError("Keychain could not remove the login (\(status)).")
        }
    }
}

extension AppConfiguration {
    /// Stable across YAML formatting, dictionary ordering, and machine-only switches.
    func syncFingerprint() throws -> String {
        var portable = self
        portable.settings.enabled = true
        portable.settings.launchAtLogin = false
        portable.profiles = portable.profiles?.map { profile in
            var profile = profile
            profile.settings.enabled = true
            profile.settings.launchAtLogin = false
            return profile
        }
        func canonical(_ value: Any, key: String = "") -> Any {
            if let object = value as? [String: Any] {
                return object.reduce(into: [String: Any]()) { result, entry in
                    result[entry.key] = canonical(entry.value, key: entry.key)
                }
            }
            if let array = value as? [Any] {
                if ["profileGestures", "appleLayerGestures", "sliderBaselines", "additional", "profileActions", "profileNames"].contains(key), array.count % 2 == 0 {
                    var pairs: [(String, Any)] = []
                    for i in stride(from: 0, to: array.count, by: 2) { pairs.append((String(describing: array[i]), canonical(array[i + 1]))) }
                    return pairs.sorted { $0.0 < $1.0 }.flatMap { [$0.0, $0.1] }
                }
                if ["customTapProfiles", "removedLayerIDs"].contains(key) { return array.map { String(describing: $0) }.sorted() }
                return array.map { canonical($0) }
            }
            return value
        }
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(portable))
        return SyncFiles.digest(try JSONSerialization.data(withJSONObject: canonical(object), options: [.sortedKeys]))
    }
}

struct SyncBaseline: Codable {
    var revision: Int
    var fingerprint: String
}

enum SyncDecision: Equatable {
    case equal, upload, download, conflict
    static func decide(local: String, remote: String?, baseline: String?) -> Self {
        guard let remote else { return .upload }
        if local == remote { return .equal }
        guard let baseline else { return .conflict }
        if local == baseline { return .download }
        if remote == baseline { return .upload }
        return .conflict
    }
    static func forAccount(local: String, remote: String?, baseline: String?,
                           ownerMatches: Bool, hasPreviousOwner: Bool,
                           firstLogin: Bool, allowInitialUpload: Bool) -> Self {
        if !ownerMatches {
            if let remote { return local == remote ? .equal : .download }
            if hasPreviousOwner && !allowInitialUpload { return .conflict }
        }
        if firstLogin && baseline == nil && remote != nil { return local == remote ? .equal : .download }
        return decide(local: local, remote: remote, baseline: baseline)
    }
}

/// File IO and YAML decoding never run in the trackpad's main-actor report path.
actor SyncFiles {
    let directory: URL
    let file: URL
    static let maximumBytes = 1_048_576
    private var lastBackupMicroseconds: Int64 = 0
    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/rotagivan", isDirectory: true)) {
        self.directory = directory
        file = directory.appendingPathComponent("settings.yaml")
    }
    nonisolated static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private func prepare() throws {
        let fm = FileManager.default
        if let attributes = try attributesIfPresent(directory) {
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw ConfigurationError("The Rotagivan config directory must not be a symbolic link.")
            }
        } else { try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
    private func readData(_ url: URL) throws -> Data? {
        guard let attributes = try attributesIfPresent(url) else { return nil }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= Self.maximumBytes else {
            throw ConfigurationError("The settings file must be a regular file no larger than 1 MB.")
        }
        return try Data(contentsOf: url)
    }
    private func attributesIfPresent(_ url: URL) throws -> [FileAttributeKey: Any]? {
        // URL resource values may be cached. Always inspect the current directory entry,
        // including dangling symlinks (fileExists follows them and returns false).
        do { return try FileManager.default.attributesOfItem(atPath: url.path) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain &&
            [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { return nil }
    }
    func read() throws -> (AppConfiguration, String)? {
        guard let data = try readData(file), let yaml = String(data: data, encoding: .utf8) else { return nil }
        return (try AppConfiguration.parse(yaml), Self.digest(data))
    }
    func rawDigest() throws -> String? { try readData(file).map(Self.digest) }
    func save(_ config: AppConfiguration, expectedDigest: String?, force: Bool = false) throws -> String {
        try prepare()
        let current = try readData(file)
        if !force, current.map(Self.digest) != expectedDigest {
            try backupConflict(config)
            throw ConfigurationError("settings.yaml changed outside the app. Reload YAML or choose Save app settings before syncing.")
        }
        if force, let current { try backupData(current) }
        let data = Data(try config.yaml().utf8)
        guard data.count <= Self.maximumBytes else { throw ConfigurationError("Configuration is larger than 1 MB.") }
        try writePrivate(data, to: file)
        return Self.digest(data)
    }
    func backup(_ config: AppConfiguration) throws { try prepare(); try backupData(Data(try config.yaml().utf8)) }
    /// Preserve the working copy and any differing on-disk copy before asking
    /// the user to resolve a conflict. Never chooses a winner or changes either.
    func backupConflict(_ config: AppConfiguration) throws {
        try prepare()
        let working = Data(try config.yaml().utf8)
        try backupData(working)
        if let disk = try readData(file), disk != working { try backupData(disk) }
    }
    private func backupData(_ data: Data) throws {
        let folder = directory.appendingPathComponent("backup", isDirectory: true)
        let fm = FileManager.default
        if let attributes = try attributesIfPresent(folder) {
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw ConfigurationError("The backup directory must not be a symbolic link or file.")
            }
        } else {
            try fm.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        var micros = max(Int64(Date().timeIntervalSince1970 * 1_000_000), lastBackupMicroseconds + 1)
        while true {
            let stamp = formatter.string(from: Date(timeIntervalSince1970: Double(micros / 1_000_000)))
            let name = "settings-\(stamp)-\(String(format: "%06lld", micros % 1_000_000))Z.yaml"
            let url = folder.appendingPathComponent(name)
            do {
                // Exclusive creation also protects against collisions across app
                // processes or a clock adjustment. Existing backups are immutable.
                try data.write(to: url, options: .withoutOverwriting)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                lastBackupMicroseconds = micros
                return
            } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError {
                micros += 1
            }
        }
    }
    private func writePrivate(_ data: Data, to url: URL) throws {
        if let attributes = try attributesIfPresent(url), attributes[.type] as? FileAttributeType != .typeRegular {
            throw ConfigurationError("Refusing to overwrite a symbolic link.")
        }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    func baseline(for account: String) throws -> SyncBaseline? {
        let url = directory.appendingPathComponent("sync-state.json")
        guard let data = try readData(url) else { return nil }
        return try JSONDecoder().decode([String: SyncBaseline].self, from: data)[account]
    }
    func setBaseline(_ baseline: SyncBaseline, for account: String) throws {
        try prepare()
        let url = directory.appendingPathComponent("sync-state.json")
        var all = try readData(url).map { try JSONDecoder().decode([String: SyncBaseline].self, from: $0) } ?? [:]
        all[account] = baseline
        try writePrivate(JSONEncoder().encode(all), to: url)
    }
}
