import Foundation

@main struct SettingsPersistenceTests {
    static func main() throws {
        try managedFiles()
        try legacyInstall()
        print("PASS SettingsPersistenceTests: verified encrypted migration, retry, tamper and symlink rejection, and the Rotagivan → Rota key and folder migration")
    }

    static func managedFiles() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("encrypted-migration-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root.appendingPathComponent("backup"), withIntermediateDirectories: true)
        let key = Data(repeating: 11, count: 32)
        let data = Data("fixture private bookmark https://private.test".utf8)
        let current = root.appendingPathComponent("settings.yaml")
        let backup = root.appendingPathComponent("backup/settings-fixture.yaml")
        try data.write(to: current); try data.write(to: backup)
        try SettingsPersistence.migrateManagedFiles(key: key, root: root)
        for file in [current, backup] {
            precondition(!fm.fileExists(atPath: file.path))
            let archive = try Data(contentsOf: file.appendingPathExtension("encrypted"))
            precondition(archive.range(of: data) == nil)
            let decoded = try JSONDecoder().decode(SettingsCipherEnvelope.self, from: archive)
                .open(master: key, scope: "legacy-snapshots", purpose: file.lastPathComponent)
            precondition(decoded == data)
        }
        try SettingsPersistence.migrateManagedFiles(key: key, root: root)
        // A replaced or tampered archive must never cause the source to be removed.
        try data.write(to: current)
        try Data("bad archive".utf8).write(to: current.appendingPathExtension("encrypted"))
        do {
            try SettingsPersistence.migrateManagedFiles(key: key, root: root)
            preconditionFailure("Tampered archive accepted")
        } catch {}
        precondition(fm.fileExists(atPath: current.path))
        // No write-through or read-through of an attacker-controlled archive link.
        try fm.removeItem(at: current.appendingPathExtension("encrypted"))
        let outside = root.appendingPathComponent("untouched")
        try data.write(to: outside)
        try fm.createSymbolicLink(at: current.appendingPathExtension("encrypted"), withDestinationURL: outside)
        do {
            try SettingsPersistence.migrateManagedFiles(key: key, root: root)
            preconditionFailure("Archive symlink accepted")
        } catch {}
        let unchanged = try Data(contentsOf: outside)
        precondition(unchanged == data && fm.fileExists(atPath: current.path))
    }

    /// An in-memory stand-in for the login Keychain, keyed by service.
    final class FakeKeys {
        var items: [String: Data]
        var reads: [String] = []
        var adds = 0
        init(_ items: [String: Data]) { self.items = items }
        var store: SettingsPersistence.KeyStore {
            SettingsPersistence.KeyStore(
                read: { service, _ in self.reads.append(service); return self.items[service] },
                add: { key, service in
                    precondition(self.items[service] == nil, "overwrote an existing key")
                    self.items[service] = key; self.adds += 1
                })
        }
    }

    static func legacyInstall() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("rename-migration-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let legacyFolder = root.appendingPathComponent("Rotagivan", isDirectory: true)
        let folder = root.appendingPathComponent("Rota", isDirectory: true)
        let database = Data("sqlite fixture".utf8)
        func seedLegacy() throws {
            try fm.createDirectory(at: legacyFolder.appendingPathComponent("Settings"), withIntermediateDirectories: true)
            try fm.createDirectory(at: legacyFolder.appendingPathComponent("Favicons"), withIntermediateDirectories: true)
            try database.write(to: legacyFolder.appendingPathComponent("Settings/settings.sqlite"))
        }
        func migrate(_ keys: FakeKeys) throws {
            try SettingsPersistence.migrateLegacyInstall(allowInteraction: false, keys: keys.store,
                legacyService: "old.service", service: "new.service", legacyFolder: legacyFolder, folder: folder)
        }
        let oldKey = Data(repeating: 7, count: 32)

        // Fresh install: nothing to migrate, nothing created, no key written.
        let fresh = FakeKeys([:])
        try migrate(fresh)
        precondition(fresh.items.isEmpty && fresh.adds == 0 && !fm.fileExists(atPath: folder.path))

        // Existing Rotagivan install: key copied, whole folder moved, old key kept.
        try seedLegacy()
        let upgrade = FakeKeys(["old.service": oldKey])
        try migrate(upgrade)
        precondition(upgrade.items["new.service"] == oldKey && upgrade.items["old.service"] == oldKey && upgrade.adds == 1)
        precondition(!fm.fileExists(atPath: legacyFolder.path))
        var moved = try Data(contentsOf: folder.appendingPathComponent("Settings/settings.sqlite"))
        precondition(moved == database)
        precondition(fm.fileExists(atPath: folder.appendingPathComponent("Favicons").path))

        // Running again is a no-op: the new key is found first and the old service is never consulted.
        try migrate(upgrade)
        precondition(upgrade.adds == 1 && upgrade.reads.last == "new.service")

        // Both folders present: both are left alone unless only the database is missing.
        try seedLegacy()
        try Data("other".utf8).write(to: legacyFolder.appendingPathComponent("Settings/settings.sqlite"))
        try migrate(upgrade)
        precondition(fm.fileExists(atPath: legacyFolder.appendingPathComponent("Settings/settings.sqlite").path))
        moved = try Data(contentsOf: folder.appendingPathComponent("Settings/settings.sqlite"))
        precondition(moved == database)
        try fm.removeItem(at: folder.appendingPathComponent("Settings"))
        try migrate(upgrade)
        precondition(!fm.fileExists(atPath: legacyFolder.appendingPathComponent("Settings").path))
        moved = try Data(contentsOf: folder.appendingPathComponent("Settings/settings.sqlite"))
        precondition(moved == Data("other".utf8))
        precondition(fm.fileExists(atPath: legacyFolder.appendingPathComponent("Favicons").path))

        // A key already under the new service is never replaced by the old one.
        let newKey = Data(repeating: 9, count: 32)
        let both = FakeKeys(["old.service": oldKey, "new.service": newKey])
        try migrate(both)
        precondition(both.items["new.service"] == newKey && both.adds == 0)

        // A Keychain refusal (locked, or approval needed) stops before touching folders.
        try fm.removeItem(at: folder)
        var refusing = FakeKeys(["old.service": oldKey]).store
        refusing.read = { _, _ in throw EncryptedSettingsError.databaseFailure }
        do {
            try SettingsPersistence.migrateLegacyInstall(allowInteraction: false, keys: refusing,
                legacyService: "old.service", service: "new.service", legacyFolder: legacyFolder, folder: folder)
            preconditionFailure("Keychain failure ignored")
        } catch {}
        precondition(fm.fileExists(atPath: legacyFolder.path) && !fm.fileExists(atPath: folder.path))
    }
}
