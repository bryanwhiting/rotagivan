import Foundation

@main struct SyncStorageTests {
    static func check(_ value: Bool) { precondition(value) }
    static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("rotagivan-sync-tests-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let files = SyncFiles(directory: root.appendingPathComponent("config"))
        let source = try String(contentsOfFile: "Rotagivan/DefaultConfiguration.yaml", encoding: .utf8)
        let config = try AppConfiguration.parse(source)
        let first = try await files.save(config, expectedDigest: nil)
        let file = files.file
        let read = try await files.read()!
        check(read.1 == first)
        check(try config.syncFingerprint() == read.0.syncFingerprint())
        let attrs = try fm.attributesOfItem(atPath: file.path)
        check((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let parentAttrs = try fm.attributesOfItem(atPath: file.deletingLastPathComponent().path)
        check((parentAttrs[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        var changed = config
        changed.settings.normal.cursorSpeed += 0.01
        let second = try await files.save(changed, expectedDigest: first)
        do { _ = try await files.save(config, expectedDigest: first); fatalError("Stale local save succeeded") }
        catch is ConfigurationError {}
        check(try await files.rawDigest() == second)
        let forced = try await files.save(config, expectedDigest: nil, force: true)
        let backupDirectory = file.deletingLastPathComponent().appendingPathComponent("backup")
        let backups = try fm.contentsOfDirectory(at: backupDirectory, includingPropertiesForKeys: nil).sorted { $0.path < $1.path }
        check(backups.count == 3) // Both conflict copies, then the replaced disk copy.
        let backup = try AppConfiguration.parse(String(contentsOf: backups.last!, encoding: .utf8))
        check(try backup.syncFingerprint() == changed.syncFingerprint())
        let originalBackups = try backups.map { try Data(contentsOf: $0) }
        for _ in 0..<20 { try await files.backup(config) }
        let allBackups = try fm.contentsOfDirectory(at: backupDirectory, includingPropertiesForKeys: nil)
        check(allBackups.count == 23)
        for url in allBackups {
            check(url.lastPathComponent.range(of: #"^settings-[0-9]{8}-[0-9]{6}-[0-9]{6}Z\.yaml$"#, options: .regularExpression) != nil)
            check((try fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
            _ = try AppConfiguration.parse(String(contentsOf: url, encoding: .utf8))
        }
        check((try fm.attributesOfItem(atPath: backupDirectory.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        check(try backups.map { try Data(contentsOf: $0) } == originalBackups)
        // A redirected backup directory must fail before settings can be replaced.
        let heldBackups = root.appendingPathComponent("held-backups")
        try fm.moveItem(at: backupDirectory, to: heldBackups)
        try fm.createSymbolicLink(at: backupDirectory, withDestinationURL: heldBackups)
        do { _ = try await files.save(changed, expectedDigest: forced, force: true); fatalError("Backup symlink accepted") }
        catch is ConfigurationError {}
        check(try await files.rawDigest() == forced)
        try fm.removeItem(at: backupDirectory)
        try fm.moveItem(at: heldBackups, to: backupDirectory)
        check(forced == first)
        try await files.setBaseline(SyncBaseline(revision: 7, fingerprint: "A"), for: "server/alice")
        try await files.setBaseline(SyncBaseline(revision: 2, fingerprint: "B"), for: "server/bob")
        let alice = try await files.baseline(for: "server/alice")
        let bob = try await files.baseline(for: "server/bob")
        check(alice?.revision == 7 && bob?.revision == 2)
        let other = try await files.baseline(for: "other-server/alice")
        check(other == nil)
        try Data("invalid: [".utf8).write(to: file)
        do { _ = try await files.read(); fatalError("Invalid YAML accepted") } catch {}
        try fm.removeItem(at: file)
        let target = root.appendingPathComponent("untouched.yaml")
        try Data(source.utf8).write(to: target)
        try fm.createSymbolicLink(at: file, withDestinationURL: target)
        do { _ = try await files.save(changed, expectedDigest: nil, force: true); fatalError("Symlink overwritten") } catch {}
        check(try String(contentsOf: target, encoding: .utf8) == source)
        var machine = config
        machine.settings.enabled.toggle(); machine.settings.launchAtLogin.toggle()
        check(try machine.syncFingerprint() == config.syncFingerprint())
        var profiles = config
        profiles.activeConfigurationID = "default"
        profiles.profiles = [ConfigurationProfile(id: "default", name: "Default", settings: config.settings, shortcuts: config.shortcuts)]
        var localProfileSwitches = profiles
        localProfileSwitches.profiles![0].settings.enabled.toggle()
        localProfileSwitches.profiles![0].settings.launchAtLogin.toggle()
        check(try profiles.syncFingerprint() == localProfileSwitches.syncFingerprint())
        localProfileSwitches.profiles![0].name = "Renamed"
        check(try profiles.syncFingerprint() != localProfileSwitches.syncFingerprint())
        var order = config
        order.settings.profileNames = [1:"One",2:"Two",100:"Three"]
        order.settings.customTapProfiles = [1,2]
        var reordered = order
        reordered.settings.profileNames = [100:"Three",2:"Two",1:"One"]
        reordered.settings.customTapProfiles = [2,1]
        check(try order.syncFingerprint() == reordered.syncFingerprint())
        check(SyncDecision.decide(local:"a",remote:nil,baseline:nil) == .upload)
        check(SyncDecision.decide(local:"a",remote:"a",baseline:nil) == .equal)
        check(SyncDecision.decide(local:"a",remote:"b",baseline:nil) == .conflict)
        check(SyncDecision.decide(local:"a",remote:"b",baseline:"a") == .download)
        check(SyncDecision.decide(local:"a",remote:"b",baseline:"b") == .upload)
        check(SyncDecision.decide(local:"a",remote:"b",baseline:"c") == .conflict)
        check(SyncDecision.forAccount(local:"alice",remote:"bob",baseline:"bob",ownerMatches:false,
            hasPreviousOwner:true,firstLogin:true,allowInitialUpload:false) == .download)
        check(SyncDecision.forAccount(local:"alice",remote:nil,baseline:nil,ownerMatches:false,
            hasPreviousOwner:true,firstLogin:true,allowInitialUpload:false) == .conflict)
        check(SyncDecision.forAccount(local:"local",remote:nil,baseline:nil,ownerMatches:false,
            hasPreviousOwner:false,firstLogin:true,allowInitialUpload:true) == .upload)
        check(SyncDecision.forAccount(local:"edited",remote:"remote",baseline:"base",ownerMatches:true,
            hasPreviousOwner:true,firstLogin:true,allowInitialUpload:false) == .conflict)
        print("Sync storage passed: private atomic YAML, roundtrip, stale-write rejection, backups, per-user baselines, invalid input, symlink protection, stable fingerprints, and conflict decisions.")
    }
}
