import AppKit
import CryptoKit
import Foundation
import Security

/// The release manifest published by scripts/release.sh at
/// https://rota.silvermine.dev/latest.json.
struct ReleaseManifest: Decodable, Equatable {
    struct Archive: Decodable, Equatable {
        let url: String
        var sha256: String? = nil
        var size: Int? = nil
    }

    let version: String
    let build: String
    let url: String
    let sha256: String?
    let minimumOS: String?
    /// The zip of the signed bundle; what the in-app installer uses.
    var zip: Archive? = nil

    /// Stable identity used for "Skip This Version".
    var identity: String { "\(version) (\(build))" }
}

enum UpdateVersion {
    /// Compares dotted numeric strings ("1.10.0" > "1.9.3"). Missing components
    /// count as zero; any non-digit suffix in a component is ignored.
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let a = components(lhs), b = components(rhs)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    /// Remote is newer when its marketing version is higher, or the version is
    /// equal and its build number is higher.
    static func isNewer(remoteVersion: String, remoteBuild: String, localVersion: String, localBuild: String) -> Bool {
        switch compare(remoteVersion, localVersion) {
        case .orderedDescending: return true
        case .orderedAscending: return false
        case .orderedSame: return compare(remoteBuild, localBuild) == .orderedDescending
        }
    }

    static func supports(minimumOS: String?, current: OperatingSystemVersion) -> Bool {
        guard let minimumOS, !minimumOS.isEmpty else { return true }
        let running = "\(current.majorVersion).\(current.minorVersion).\(current.patchVersion)"
        return compare(running, minimumOS) != .orderedAscending
    }

    private static func components(_ value: String) -> [Int] {
        value.trimmingCharacters(in: .whitespaces).split(separator: ".", omittingEmptySubsequences: false).map {
            Int($0.prefix { $0.isASCII && $0.isNumber }) ?? 0
        }
    }
}

/// Pure scheduling/prompt decisions, kept separate from networking and UI so
/// they can be unit tested.
enum UpdatePolicy {
    static let checkInterval: TimeInterval = 24 * 60 * 60

    static func isDue(lastCheck: Date?, now: Date) -> Bool {
        guard let lastCheck else { return true }
        // A clock moved backwards also makes a check due.
        return now.timeIntervalSince(lastCheck) >= checkInterval || now < lastCheck
    }

    enum Decision: Equatable { case upToDate, unsupportedOS, skipped, prompt }

    static func decide(_ manifest: ReleaseManifest, localVersion: String, localBuild: String,
                       skippedIdentity: String?, userInitiated: Bool, os: OperatingSystemVersion) -> Decision {
        guard UpdateVersion.isNewer(remoteVersion: manifest.version, remoteBuild: manifest.build,
                                    localVersion: localVersion, localBuild: localBuild) else { return .upToDate }
        guard UpdateVersion.supports(minimumOS: manifest.minimumOS, current: os) else { return .unsupportedOS }
        if !userInitiated, skippedIdentity == manifest.identity { return .skipped }
        return .prompt
    }

    /// Only HTTPS downloads from the manifest's own host are opened.
    static func downloadURL(for manifest: ReleaseManifest, manifestURL: URL) -> URL? {
        downloadURL(for: manifest.url, manifestURL: manifestURL)
    }

    static func downloadURL(for reference: String, manifestURL: URL) -> URL? {
        guard let url = URL(string: reference, relativeTo: manifestURL)?.absoluteURL,
              url.scheme == "https", url.host == manifestURL.host else { return nil }
        return url
    }
}

/// Replaces the running bundle with the release's zip: download, SHA-256,
/// bundle identity and version, then the same code-signing requirement as the
/// running copy (so a tampered or foreign build is refused and the existing
/// Accessibility / Input Monitoring grants carry over). The swap itself runs
/// in a detached shell after the app quits. Downloads made this way carry no
/// quarantine flag, so Gatekeeper is not involved.
enum UpdateInstall {
    struct Plan: Equatable {
        let archive: URL
        let sha256: String
    }

    enum Failure: LocalizedError {
        case downloadFailed(String)
        case checksumMismatch
        case archiveLayout
        case wrongBundle(String)
        case signature(String)
        case swapFailed(String)

        var errorDescription: String? {
            switch self {
            case .downloadFailed(let why): return "The download failed: \(why)"
            case .checksumMismatch: return "The downloaded file does not match the published checksum."
            case .archiveLayout: return "The download did not contain exactly one app."
            case .wrongBundle(let why): return "The download is not the expected release: \(why)"
            case .signature(let why): return "The download is not signed like this copy of Rota: \(why)"
            case .swapFailed(let why): return "Rota could not be replaced: \(why)"
            }
        }
    }

    /// The zip is installable only with a full SHA-256 and an HTTPS URL on the manifest's host.
    static func plan(for manifest: ReleaseManifest, manifestURL: URL) -> Plan? {
        guard let zip = manifest.zip, let sha = zip.sha256?.lowercased(), sha.count == 64,
              sha.allSatisfy({ $0.isHexDigit }),
              let url = UpdatePolicy.downloadURL(for: zip.url, manifestURL: manifestURL) else { return nil }
        return Plan(archive: url, sha256: sha)
    }

    /// In-place replacement needs a `.app` bundle on a writable volume whose
    /// parent folder we can write to (e.g. /Applications), not a copy still
    /// running from a disk image or a build folder we should not touch.
    static func canReplace(bundleURL: URL, fileManager: FileManager = .default) -> Bool {
        let path = bundleURL.standardizedFileURL.path
        guard path.hasSuffix(".app"), !path.contains("/Volumes/"), !path.contains("/.Trash/") else { return false }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return false }
        if let readOnly = try? bundleURL.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly, readOnly { return false }
        return fileManager.isWritableFile(atPath: bundleURL.deletingLastPathComponent().path)
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The script that waits for this process to exit, swaps the bundles
    /// (keeping the old one until the copy succeeded) and reopens the app.
    static func swapScript(pid: Int32, staged: URL, target: URL, stagingDirectory: URL) -> String {
        let s = shellQuote(staged.path), t = shellQuote(target.path), d = shellQuote(stagingDirectory.path)
        return """
        #!/bin/sh
        n=0
        while /bin/kill -0 \(pid) 2>/dev/null; do
          n=$((n + 1)); [ $n -gt 150 ] && /bin/kill -TERM \(pid) 2>/dev/null
          [ $n -gt 200 ] && break
          /bin/sleep 0.2
        done
        old=\(t).previous.$$
        /bin/mv \(t) "$old" || exit 1
        if /usr/bin/ditto \(s) \(t); then
          /bin/rm -rf "$old"
        else
          /bin/rm -rf \(t); /bin/mv "$old" \(t); exit 1
        fi
        /usr/bin/open \(t)
        /bin/rm -rf \(d)

        """
    }

    static func sha256(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The running code's designated requirement: identifier + the pinned signing certificate.
    static func requirementOfRunningCode() throws -> SecRequirement {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { throw Failure.signature("cannot identify the running code") }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { throw Failure.signature("cannot read the running code") }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess, let requirement else {
            throw Failure.signature("the running copy has no designated requirement")
        }
        return requirement
    }

    static func verify(bundle: URL, satisfies requirement: SecRequirement) throws {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &staticCode) == errSecSuccess, let staticCode else {
            throw Failure.signature("unreadable bundle")
        }
        let flags = SecCSFlags(rawValue: UInt32(kSecCSCheckAllArchitectures) | UInt32(kSecCSCheckNestedCode) | UInt32(kSecCSStrictValidate))
        var error: Unmanaged<CFError>?
        let status = SecStaticCodeCheckValidityWithErrors(staticCode, flags, requirement, &error)
        guard status == errSecSuccess else {
            _ = error?.takeRetainedValue()
            let detail = (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
            throw Failure.signature(detail)
        }
    }

    static func run(_ executable: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// Downloads and stages the release; returns the staged bundle and its
    /// staging directory. Everything is verified before anything is replaced.
    static func stage(_ plan: Plan, manifest: ReleaseManifest, session: URLSession) async throws -> (app: URL, directory: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rota-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var request = URLRequest(url: plan.archive)
        request.setValue("Rota/\(AppVersion.version) (\(AppVersion.build))", forHTTPHeaderField: "User-Agent")
        let (downloaded, response): (URL, URLResponse)
        do {
            (downloaded, response) = try await session.download(for: request)
        } catch {
            throw Failure.downloadFailed(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw Failure.downloadFailed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        let archive = directory.appendingPathComponent("Rota.zip")
        try FileManager.default.moveItem(at: downloaded, to: archive)
        guard try sha256(ofFileAt: archive) == plan.sha256 else { throw Failure.checksumMismatch }

        let unpacked = directory.appendingPathComponent("unpacked")
        guard try run("/usr/bin/ditto", ["-x", "-k", archive.path, unpacked.path]) == 0 else { throw Failure.archiveLayout }
        let apps = try FileManager.default.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "app" }
        guard apps.count == 1, let app = apps.first else { throw Failure.archiveLayout }

        guard let info = Bundle(url: app)?.infoDictionary else { throw Failure.wrongBundle("no Info.plist") }
        guard info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else {
            throw Failure.wrongBundle("bundle identifier \(info["CFBundleIdentifier"] ?? "?")")
        }
        guard info["CFBundleShortVersionString"] as? String == manifest.version,
              info["CFBundleVersion"] as? String == manifest.build else {
            throw Failure.wrongBundle("it is \(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?")), not \(manifest.identity)")
        }
        try verify(bundle: app, satisfies: try requirementOfRunningCode())
        return (app, directory)
    }

    /// Hands the swap to a detached shell and returns; the caller terminates the app.
    static func scheduleSwap(staged: URL, stagingDirectory: URL, target: URL) throws {
        let script = stagingDirectory.appendingPathComponent("install.sh")
        let text = swapScript(pid: ProcessInfo.processInfo.processIdentifier, staged: staged, target: target, stagingDirectory: stagingDirectory)
        try text.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw Failure.swapFailed(error.localizedDescription) }
    }
}

/// Checks rota.silvermine.dev for a newer release shortly after launch, then
/// about once a day, and offers to download it. State is machine-local
/// (UserDefaults.standard), never part of synced settings.
@MainActor
final class UpdateChecker {
    static let shared = UpdateChecker()
    static let manifestURL = URL(string: "https://rota.silvermine.dev/latest.json")!
    static let downloadPageURL = URL(string: "https://rota.silvermine.dev/download/")!

    private let defaults = UserDefaults.standard
    private let skippedKey = "update.skippedVersion"
    private let lastCheckKey = "update.lastCheck"
    private var timer: Timer?
    private var checking = false

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    /// The manifest session's 20 s resource timeout is too short for the archive.
    private lazy var downloadSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 10 * 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    /// Schedules the automatic checks. Safe to call more than once.
    func start() {
        guard timer == nil, automaticChecksAllowed else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.checkIfDue() }
        // Hourly wake-ups; a network request happens only when a day has passed.
        timer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkIfDue() }
        }
    }

    /// "Check for Updates…": always reports the outcome.
    func checkNow() {
        Task { await check(userInitiated: true) }
    }

    private var automaticChecksAllowed: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["ROTA_DISABLE_UPDATE_CHECK"] == nil
            && !ProcessInfo.processInfo.arguments.contains("--no-update-check")
            && Bundle.main.bundleIdentifier == "local.rota"
    }

    private func checkIfDue() {
        guard UpdatePolicy.isDue(lastCheck: defaults.object(forKey: lastCheckKey) as? Date, now: Date()) else { return }
        Task { await check(userInitiated: false) }
    }

    private func check(userInitiated: Bool) async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        let manifest: ReleaseManifest
        do {
            manifest = try await fetchManifest()
        } catch {
            // Automatic checks fail silently and retry on the next hourly wake-up.
            if userInitiated { report("Couldn't check for updates", "Rota couldn't reach rota.silvermine.dev. Check your connection and try again.") }
            return
        }
        defaults.set(Date(), forKey: lastCheckKey)
        let decision = UpdatePolicy.decide(manifest, localVersion: AppVersion.version, localBuild: AppVersion.build,
                                           skippedIdentity: defaults.string(forKey: skippedKey),
                                           userInitiated: userInitiated, os: ProcessInfo.processInfo.operatingSystemVersion)
        switch decision {
        case .upToDate:
            if userInitiated { report("You're up to date", "Rota \(AppVersion.version) (\(AppVersion.build)) is the latest version.") }
        case .unsupportedOS:
            if userInitiated { report("Update requires a newer macOS", "Rota \(manifest.version) requires macOS \(manifest.minimumOS ?? "") or later.") }
        case .skipped:
            return
        case .prompt:
            prompt(manifest)
        }
    }

    private func fetchManifest() async throws -> ReleaseManifest {
        var request = URLRequest(url: Self.manifestURL)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Rota/\(AppVersion.version) (\(AppVersion.build))", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count < 64 * 1024 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(ReleaseManifest.self, from: data)
    }

    private func prompt(_ manifest: ReleaseManifest) {
        let plan = UpdateInstall.canReplace(bundleURL: Bundle.main.bundleURL)
            ? UpdateInstall.plan(for: manifest, manifestURL: Self.manifestURL) : nil
        let alert = NSAlert()
        alert.messageText = "Rota \(manifest.version) is available"
        alert.informativeText = plan != nil
            ? "You have \(AppVersion.version) (\(AppVersion.build)). Rota downloads the new version, verifies it, replaces this copy and reopens. Your settings and permissions are kept."
            : "You have \(AppVersion.version) (\(AppVersion.build)). Download the new version, open it, and drag Rota to Applications to replace this one."
        alert.addButton(withTitle: plan != nil ? "Install and Relaunch" : "Download")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Skip This Version")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            defaults.removeObject(forKey: skippedKey)
            if let plan {
                Task { await install(plan, manifest: manifest) }
            } else {
                NSWorkspace.shared.open(UpdatePolicy.downloadURL(for: manifest, manifestURL: Self.manifestURL) ?? Self.downloadPageURL)
            }
        case .alertThirdButtonReturn:
            defaults.set(manifest.identity, forKey: skippedKey)
        default:
            break
        }
    }

    private func install(_ plan: UpdateInstall.Plan, manifest: ReleaseManifest) async {
        do {
            let staged = try await UpdateInstall.stage(plan, manifest: manifest, session: downloadSession)
            try UpdateInstall.scheduleSwap(staged: staged.app, stagingDirectory: staged.directory, target: Bundle.main.bundleURL)
            NSApp.terminate(nil)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't install Rota \(manifest.version)"
            alert.informativeText = "\(error.localizedDescription)\n\nYou can download it from rota.silvermine.dev instead."
            alert.addButton(withTitle: "Open Download Page")
            alert.addButton(withTitle: "Later")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(Self.downloadPageURL)
            }
        }
    }

    private func report(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
