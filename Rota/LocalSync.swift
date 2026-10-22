import Foundation

/// Local mode: the complete configuration lives in `settings.yaml` inside a
/// folder the user owns. The app writes it after every edit and reloads it when
/// something else (an editor, `git pull`, another Mac via a synced folder)
/// changes it. If the folder is a git repository the app can commit, push and
/// pull for you. API keys never enter this file; they come from `~/.env`.
actor LocalFileSync {
    enum Failure: Error, LocalizedError, Equatable {
        case diskChanged, git(String), notRepository, gitUnavailable
        var errorDescription: String? {
            switch self {
            case .diskChanged: return "settings.yaml changed on disk while this Mac was editing."
            case .git(let output): return output.isEmpty ? "git failed." : output
            case .notRepository: return "This folder is not a git repository."
            case .gitUnavailable: return "git is not installed. Install the Xcode command line tools (xcode-select --install)."
            }
        }
    }
    let files: SyncFiles
    var folder: URL { files.directory }
    var file: URL { files.file }
    /// Digest of the file content this Mac last wrote or loaded.
    private(set) var knownDigest: String?
    private let git: GitRunner

    init(folder: URL, git: GitRunner = GitRunner()) {
        files = SyncFiles(directory: folder)
        self.git = git
    }

    /// Writes when the content differs from the file. Throws `diskChanged` when
    /// the file no longer matches what this Mac last saw, so the caller decides
    /// which side wins; `force` writes anyway and keeps a backup of the disk copy.
    @discardableResult
    func write(_ configuration: AppConfiguration, force: Bool = false) async throws -> String {
        let current = try await files.rawDigest()
        if let current, let knownDigest, current == knownDigest {
            let candidate = SyncFiles.digest(Data(try configuration.yaml().utf8))
            if candidate == current { return current }
        }
        if !force, let current, current != knownDigest {
            throw Failure.diskChanged
        }
        let digest = try await files.save(configuration, expectedDigest: force ? nil : knownDigest, force: force || knownDigest == nil)
        knownDigest = digest
        return digest
    }
    /// The configuration on disk when it differs from what this Mac last saw.
    func readIfChanged() async throws -> (AppConfiguration, String)? {
        guard let (configuration, digest) = try await files.read(), digest != knownDigest else { return nil }
        return (configuration, digest)
    }
    func acknowledge(_ digest: String) { knownDigest = digest }
    func exists() async throws -> Bool { try await files.rawDigest() != nil }
    func modificationDate() async throws -> Date? { try await files.modificationDate() }
    func backup(_ configuration: AppConfiguration) async throws { try await files.backup(configuration) }

    // MARK: git

    var isRepository: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: folder.appendingPathComponent(".git").path, isDirectory: &isDirectory)
    }
    func remoteName() async -> String? {
        guard isRepository, let output = try? await git.run(["remote"], in: folder) else { return nil }
        let remotes = output.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
        return remotes.contains("origin") ? "origin" : remotes.first
    }
    func initializeRepository() async throws {
        try await git.run(["init", "-q"], in: folder)
        let ignore = folder.appendingPathComponent(".gitignore")
        if !FileManager.default.fileExists(atPath: ignore.path) {
            try Data("backup/\n*.encrypted\n".utf8).write(to: ignore, options: .atomic)
        }
    }
    /// Stages settings.yaml, commits when it changed, pushes when a remote exists.
    @discardableResult
    func commitAndPush(message: String) async throws -> String {
        guard isRepository else { throw Failure.notRepository }
        var log = ""
        try await git.run(["add", "--", file.lastPathComponent, ".gitignore"], in: folder)
        let status = try await git.run(["status", "--porcelain", "--", file.lastPathComponent, ".gitignore"], in: folder)
        if !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try await git.run(["commit", "-q", "-m", message, "--", file.lastPathComponent, ".gitignore"], in: folder)
            log += "Committed. "
        } else { log += "Nothing new to commit. " }
        if let remote = await remoteName() {
            let branch = (try? await git.run(["rev-parse", "--abbrev-ref", "HEAD"], in: folder))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "HEAD"
            try await git.run(["push", "-q", "-u", remote, branch], in: folder)
            log += "Pushed to \(remote)."
        }
        return log.trimmingCharacters(in: .whitespaces)
    }
    /// Fast-forward only: a diverged history is reported, never merged silently.
    @discardableResult
    func pull() async throws -> String {
        guard isRepository else { throw Failure.notRepository }
        guard await remoteName() != nil else { return "No remote configured." }
        let output = try await git.run(["pull", "-q", "--ff-only"], in: folder)
        return output.isEmpty ? "Pulled." : output
    }
}

/// Runs git non-interactively with a bounded wait. Output is returned for the
/// settings pane; nothing is logged.
struct GitRunner: Sendable {
    var executable = "/usr/bin/git"
    var timeout: TimeInterval = 30
    @discardableResult
    func run(_ arguments: [String], in directory: URL) async throws -> String {
        guard FileManager.default.isExecutableFile(atPath: executable) else { throw LocalFileSync.Failure.gitUnavailable }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-C", directory.path] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_ASKPASS"] = "/usr/bin/true"
        environment["SSH_ASKPASS_REQUIRE"] = "never"
        process.environment = environment
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output; process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { try? await Task.sleep(nanoseconds: 50_000_000) }
        if process.isRunning { process.terminate(); throw LocalFileSync.Failure.git("git \(arguments.first ?? "") timed out after \(Int(timeout)) s.") }
        let out = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let err = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw LocalFileSync.Failure.git((err + out).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Wakes the coordinator when the settings file is replaced by anything else.
final class SettingsFileWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var descriptor: Int32 = -1
    private let queue = DispatchQueue(label: "local.rota.settings-file-watch", qos: .utility)
    private var pending: DispatchWorkItem?
    init?(folder: URL, onChange: @escaping @Sendable () -> Void) {
        descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            pending?.cancel()
            let work = DispatchWorkItem(block: onChange)
            pending = work
            queue.asyncAfter(deadline: .now() + 0.5, execute: work)
        }
        source.setCancelHandler { [descriptor] in close(descriptor) }
        source.resume()
        self.source = source
    }
    func stop() { source?.cancel(); source = nil }
    deinit { stop() }
}
