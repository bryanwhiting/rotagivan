import Foundation

@main struct SettingsPersistenceTests {
    static func main() throws {
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
        print("PASS SettingsPersistenceTests: verified encrypted migration, retry, tamper and symlink rejection")
    }
}
