import Foundation

@main struct UpdateCheckerTests {
    static func main() throws {
        // Dotted numeric comparison, not string comparison.
        precondition(UpdateVersion.compare("1.10.0", "1.9.3") == .orderedDescending)
        precondition(UpdateVersion.compare("1.1.217", "1.1.217") == .orderedSame)
        precondition(UpdateVersion.compare("1.1", "1.1.0") == .orderedSame)
        precondition(UpdateVersion.compare("1.1.0", "1.1.1") == .orderedAscending)
        precondition(UpdateVersion.compare("2", "10") == .orderedAscending)
        precondition(UpdateVersion.compare("1.2.3-beta", "1.2.3") == .orderedSame)

        // Version first, then build.
        precondition(UpdateVersion.isNewer(remoteVersion: "1.1.218", remoteBuild: "220", localVersion: "1.1.217", localBuild: "219"))
        precondition(UpdateVersion.isNewer(remoteVersion: "1.1.217", remoteBuild: "220", localVersion: "1.1.217", localBuild: "219"))
        precondition(!UpdateVersion.isNewer(remoteVersion: "1.1.217", remoteBuild: "219", localVersion: "1.1.217", localBuild: "219"))
        precondition(!UpdateVersion.isNewer(remoteVersion: "1.1.216", remoteBuild: "300", localVersion: "1.1.217", localBuild: "219"))
        precondition(UpdateVersion.isNewer(remoteVersion: "1.2.0", remoteBuild: "1", localVersion: "1.1.999", localBuild: "999"))
        // A development build with unknown metadata is treated as older.
        precondition(UpdateVersion.isNewer(remoteVersion: "1.0.0", remoteBuild: "1", localVersion: "Development", localBuild: "—"))

        let sonoma = OperatingSystemVersion(majorVersion: 14, minorVersion: 6, patchVersion: 1)
        precondition(UpdateVersion.supports(minimumOS: "13.0", current: sonoma))
        precondition(UpdateVersion.supports(minimumOS: "14.6.1", current: sonoma))
        precondition(!UpdateVersion.supports(minimumOS: "15.0", current: sonoma))
        precondition(UpdateVersion.supports(minimumOS: nil, current: sonoma))

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        precondition(UpdatePolicy.isDue(lastCheck: nil, now: now))
        precondition(!UpdatePolicy.isDue(lastCheck: now.addingTimeInterval(-3600), now: now))
        precondition(UpdatePolicy.isDue(lastCheck: now.addingTimeInterval(-86_400), now: now))
        precondition(UpdatePolicy.isDue(lastCheck: now.addingTimeInterval(3600), now: now))

        let json = #"{"version":"1.1.218","build":"220","url":"https://rota.silvermine.dev/releases/Rotagivan-1.1.218-220.dmg","sha256":"ab","minimumOS":"13.0","size":1,"zip":{"url":"x"}}"#
        let manifest = try JSONDecoder().decode(ReleaseManifest.self, from: Data(json.utf8))
        precondition(manifest.identity == "1.1.218 (220)")
        let decide = { (skipped: String?, user: Bool, local: String) in
            UpdatePolicy.decide(manifest, localVersion: local, localBuild: "219", skippedIdentity: skipped, userInitiated: user, os: sonoma)
        }
        precondition(decide(nil, false, "1.1.217") == .prompt)
        precondition(decide("1.1.218 (220)", false, "1.1.217") == .skipped)
        precondition(decide("1.1.218 (220)", true, "1.1.217") == .prompt)
        precondition(decide("1.1.217 (219)", false, "1.1.217") == .prompt)
        precondition(decide(nil, true, "1.1.219") == .upToDate)
        let future = ReleaseManifest(version: "9.0.0", build: "1", url: "/releases/a.dmg", sha256: nil, minimumOS: "99.0")
        precondition(UpdatePolicy.decide(future, localVersion: "1.0.0", localBuild: "1", skippedIdentity: nil, userInitiated: true, os: sonoma) == .unsupportedOS)

        let base = URL(string: "https://rota.silvermine.dev/latest.json")!
        precondition(UpdatePolicy.downloadURL(for: manifest, manifestURL: base)?.absoluteString == manifest.url)
        precondition(UpdatePolicy.downloadURL(for: future, manifestURL: base)?.absoluteString == "https://rota.silvermine.dev/releases/a.dmg")
        for unsafe in ["http://rota.silvermine.dev/a.dmg", "https://evil.example/a.dmg", "file:///tmp/a.dmg"] {
            let m = ReleaseManifest(version: "9", build: "1", url: unsafe, sha256: nil, minimumOS: nil)
            precondition(UpdatePolicy.downloadURL(for: m, manifestURL: base) == nil)
        }
        print("UpdateChecker tests passed: version/build ordering, OS minimum, daily schedule, skip, manifest decoding, HTTPS same-host downloads.")
    }
}
