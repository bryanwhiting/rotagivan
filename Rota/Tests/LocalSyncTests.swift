import Foundation

extension AppConfiguration { var speed: Double { (settings.normal.cursorSpeed * 1000).rounded() / 10 } }

@main struct LocalSyncTests {
    static func check(_ value: Bool, _ message: String = "", line: UInt = #line) { precondition(value, "line \(line): " + message) }
    static func main() async throws {
        setenv("GIT_AUTHOR_NAME", "Rota Tests", 1); setenv("GIT_AUTHOR_EMAIL", "tests@example.invalid", 1)
        setenv("GIT_COMMITTER_NAME", "Rota Tests", 1); setenv("GIT_COMMITTER_EMAIL", "tests@example.invalid", 1)
        setenv("GIT_CONFIG_GLOBAL", "/dev/null", 1); setenv("GIT_CONFIG_SYSTEM", "/dev/null", 1)
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("rota-local-sync-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let base = try AppConfiguration.parse(try String(contentsOfFile: "Rota/DefaultConfiguration.yaml", encoding: .utf8))
        func variant(_ speed: Double) -> AppConfiguration { var copy = base; copy.settings.normal.cursorSpeed = speed / 100; return copy }

        // Plain folder: write, no-op rewrite, external edit, conflict.
        let folder = root.appendingPathComponent("config")
        let local = LocalFileSync(folder: folder)
        check(try await !local.exists())
        let first = try await local.write(variant(1.0))
        check(try await local.exists())
        let file = await local.file
        check((try fm.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        check(try await local.write(variant(1.0)) == first, "identical content is not rewritten")
        check(try await local.readIfChanged() == nil, "our own write is not a change")
        let second = try await local.write(variant(2.0))
        check(second != first)
        // Something else edits the file (an editor, git pull).
        let external = try variant(3.0).yaml()
        try Data(external.utf8).write(to: file, options: .atomic)
        guard let (disk, digest) = try await local.readIfChanged() else { fatalError("external edit not detected") }
        check(disk.speed == 3.0)
        do { _ = try await local.write(variant(2.5)); fatalError("write over an unseen disk change must fail") }
        catch LocalFileSync.Failure.diskChanged {}
        await local.acknowledge(digest)
        check(try await local.readIfChanged() == nil)
        // A forced write keeps the disk copy as a backup.
        try Data(try variant(4.0).yaml().utf8).write(to: file, options: .atomic)
        _ = try await local.write(variant(5.0), force: true)
        let backups = try fm.contentsOfDirectory(at: folder.appendingPathComponent("backup"), includingPropertiesForKeys: nil)
        let backup = try AppConfiguration.parse(String(contentsOf: backups[0], encoding: .utf8))
        check(backups.count == 1 && backup.speed == 4.0)
        check(try await local.readIfChanged() == nil)
        check(await !local.isRepository)
        do { _ = try await local.commitAndPush(message: "x"); fatalError("commit outside a repository") }
        catch LocalFileSync.Failure.notRepository {}

        // Git: init, commit, push to a bare remote, pull a change made elsewhere.
        try await local.initializeRepository()
        check(await local.isRepository)
        check(try String(contentsOf: folder.appendingPathComponent(".gitignore"), encoding: .utf8).contains("backup/"))
        var log = try await local.commitAndPush(message: "first")
        check(log.hasPrefix("Committed."), log)
        log = try await local.commitAndPush(message: "again")
        check(log.hasPrefix("Nothing new to commit."), log)
        check(try await local.pull() == "No remote configured.")
        let git = GitRunner()
        let remote = root.appendingPathComponent("remote.git")
        try await git.run(["init", "-q", "--bare", remote.path], in: root)
        try await git.run(["remote", "add", "origin", remote.path], in: folder)
        check(await local.remoteName() == "origin")
        _ = try await local.write(variant(6.0), force: true)
        log = try await local.commitAndPush(message: "with remote")
        check(log.contains("Pushed to origin"), log)
        // Another Mac: clone, edit, push. This Mac pulls and sees the change.
        let other = root.appendingPathComponent("other")
        try await git.run(["clone", "-q", remote.path, other.path], in: root)
        let otherSync = LocalFileSync(folder: other)
        _ = try await otherSync.write(variant(7.0), force: true)
        _ = try await otherSync.commitAndPush(message: "from the other Mac")
        log = try await local.pull()
        check(log == "Pulled.", log)
        guard let (pulled, pulledDigest) = try await local.readIfChanged() else { fatalError("pulled change not detected") }
        check(pulled.speed == 7.0)
        await local.acknowledge(pulledDigest)
        // Diverged histories are refused, not merged silently.
        _ = try await local.write(variant(8.0), force: true)
        _ = try await local.commitAndPush(message: "local 8")
        _ = try await otherSync.write(variant(9.0), force: true)
        try await git.run(["commit", "-q", "-am", "other 9"], in: other)
        do { _ = try await otherSync.pull(); fatalError("non fast-forward pull must fail") }
        catch LocalFileSync.Failure.git(let output) { check(!output.isEmpty) }
        // A missing git binary is a clear error, not a crash.
        let noGit = LocalFileSync(folder: folder, git: GitRunner(executable: "/nonexistent/git"))
        do { _ = try await noGit.commitAndPush(message: "x"); fatalError("missing git accepted") }
        catch LocalFileSync.Failure.gitUnavailable {}
        print("Local sync passed: private YAML writes, change detection, conflict refusal with backups, git init/commit/push/pull round trip, divergence refusal, missing git.")
    }
}
