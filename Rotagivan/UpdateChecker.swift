import AppKit
import Foundation

/// The release manifest published by scripts/release.sh at
/// https://rota.silvermine.dev/latest.json.
struct ReleaseManifest: Decodable, Equatable {
    let version: String
    let build: String
    let url: String
    let sha256: String?
    let minimumOS: String?

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
        guard let url = URL(string: manifest.url, relativeTo: manifestURL)?.absoluteURL,
              url.scheme == "https", url.host == manifestURL.host else { return nil }
        return url
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
        return environment["ROTAGIVAN_DISABLE_UPDATE_CHECK"] == nil
            && !ProcessInfo.processInfo.arguments.contains("--no-update-check")
            && Bundle.main.bundleIdentifier == "local.rotagivan"
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
            if userInitiated { report("Couldn't check for updates", "Rotagivan couldn't reach rota.silvermine.dev. Check your connection and try again.") }
            return
        }
        defaults.set(Date(), forKey: lastCheckKey)
        let decision = UpdatePolicy.decide(manifest, localVersion: AppVersion.version, localBuild: AppVersion.build,
                                           skippedIdentity: defaults.string(forKey: skippedKey),
                                           userInitiated: userInitiated, os: ProcessInfo.processInfo.operatingSystemVersion)
        switch decision {
        case .upToDate:
            if userInitiated { report("You're up to date", "Rotagivan \(AppVersion.version) (\(AppVersion.build)) is the latest version.") }
        case .unsupportedOS:
            if userInitiated { report("Update requires a newer macOS", "Rotagivan \(manifest.version) requires macOS \(manifest.minimumOS ?? "") or later.") }
        case .skipped:
            return
        case .prompt:
            prompt(manifest)
        }
    }

    private func fetchManifest() async throws -> ReleaseManifest {
        var request = URLRequest(url: Self.manifestURL)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Rotagivan/\(AppVersion.version) (\(AppVersion.build))", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count < 64 * 1024 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(ReleaseManifest.self, from: data)
    }

    private func prompt(_ manifest: ReleaseManifest) {
        let alert = NSAlert()
        alert.messageText = "Rotagivan \(manifest.version) is available"
        alert.informativeText = "You have \(AppVersion.version) (\(AppVersion.build)). Download the new version, open it, and drag Rotagivan to Applications to replace this one."
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Skip This Version")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            defaults.removeObject(forKey: skippedKey)
            NSWorkspace.shared.open(UpdatePolicy.downloadURL(for: manifest, manifestURL: Self.manifestURL) ?? Self.downloadPageURL)
        case .alertThirdButtonReturn:
            defaults.set(manifest.identity, forKey: skippedKey)
        default:
            break
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
