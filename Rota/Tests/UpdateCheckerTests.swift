import CryptoKit
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

        let json = #"{"version":"1.1.218","build":"220","url":"https://rota.silvermine.dev/releases/Rota-1.1.218-220.dmg","sha256":"ab","minimumOS":"13.0","size":1,"zip":{"url":"x"}}"#
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
        // In-app install: only with a complete zip entry on the manifest's own host.
        precondition(manifest.zip?.url == "x" && manifest.zip?.sha256 == nil)
        precondition(UpdateInstall.plan(for: manifest, manifestURL: base) == nil, "no checksum, no in-app install")
        let sha = String(repeating: "ab", count: 32)
        let full = #"{"version":"1.1.250","build":"252","url":"https://rota.silvermine.dev/releases/Rota-1.1.250-252.dmg","minimumOS":"13.0","zip":{"url":"/releases/Rota-1.1.250-252.zip","sha256":"\#(sha.uppercased())","size":7}}"#
        let installable = try JSONDecoder().decode(ReleaseManifest.self, from: Data(full.utf8))
        let plan = UpdateInstall.plan(for: installable, manifestURL: base)
        precondition(plan == UpdateInstall.Plan(archive: URL(string: "https://rota.silvermine.dev/releases/Rota-1.1.250-252.zip")!, sha256: sha))
        for bad in [#"{"url":"https://evil.example/a.zip","sha256":"\#(sha)"}"#, #"{"url":"/a.zip","sha256":"abc"}"#, #"{"url":"/a.zip","sha256":"\#(String(repeating: "zz", count: 32))"}"#] {
            let json = #"{"version":"9","build":"1","url":"/a.dmg","zip":\#(bad)}"#
            let m = try JSONDecoder().decode(ReleaseManifest.self, from: Data(json.utf8))
            precondition(UpdateInstall.plan(for: m, manifestURL: base) == nil, "rejected: \(bad)")
        }

        // Replacing in place needs a writable .app bundle outside mounted volumes.
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("UpdateCheckerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let app = scratch.appendingPathComponent("Rota.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        precondition(UpdateInstall.canReplace(bundleURL: app))
        precondition(!UpdateInstall.canReplace(bundleURL: scratch.appendingPathComponent("missing.app")))
        precondition(!UpdateInstall.canReplace(bundleURL: scratch), "not an .app")
        precondition(!UpdateInstall.canReplace(bundleURL: URL(fileURLWithPath: "/Volumes/Rota 1.1.250/Rota.app")), "disk image")
        precondition(!UpdateInstall.canReplace(bundleURL: URL(fileURLWithPath: "/System/Applications/Calculator.app")), "read-only parent")

        // The swap script waits for this process, keeps the old bundle until the copy succeeded, and quotes paths.
        precondition(UpdateInstall.shellQuote("it's /Applications/Rota.app") == #"'it'\''s /Applications/Rota.app'"#)
        let script = UpdateInstall.swapScript(pid: 4242, staged: scratch.appendingPathComponent("unpacked/Rota.app"),
                                              target: URL(fileURLWithPath: "/Applications/Rota.app"), stagingDirectory: scratch)
        precondition(script.hasPrefix("#!/bin/sh\n"))
        precondition(script.contains("/bin/kill -0 4242"))
        precondition(script.contains("/bin/mv '/Applications/Rota.app' \"$old\""))
        precondition(script.contains("/usr/bin/ditto '\(scratch.path)/unpacked/Rota.app' '/Applications/Rota.app'"))
        precondition(script.contains("/bin/mv \"$old\" '/Applications/Rota.app'; exit 1"), "restores the old bundle when ditto fails")
        precondition(script.contains("/usr/bin/open '/Applications/Rota.app'"))
        precondition(script.contains("/bin/rm -rf '\(scratch.path)'"))
        // Running the script against a scratch target performs the swap for real.
        let target = scratch.appendingPathComponent("target/Rota.app")
        let staged = scratch.appendingPathComponent("unpacked/Rota.app")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        try "old".write(to: target.appendingPathComponent("marker"), atomically: true, encoding: .utf8)
        try "new".write(to: staged.appendingPathComponent("marker"), atomically: true, encoding: .utf8)
        let swap = UpdateInstall.swapScript(pid: 1, staged: staged, target: target, stagingDirectory: scratch.appendingPathComponent("unpacked"))
            .replacingOccurrences(of: "/usr/bin/open ", with: "/usr/bin/true ")
            .replacingOccurrences(of: "/bin/kill -0 1 ", with: "/usr/bin/false ")
        let scriptURL = scratch.appendingPathComponent("install.sh")
        try swap.write(to: scriptURL, atomically: true, encoding: .utf8)
        let swapStatus = try UpdateInstall.run("/bin/sh", [scriptURL.path])
        precondition(swapStatus == 0, "swap script exited \(swapStatus)")
        let marker = try String(contentsOf: target.appendingPathComponent("marker"), encoding: .utf8)
        precondition(marker == "new")
        precondition(!FileManager.default.fileExists(atPath: staged.path), "staging directory removed")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: scratch.appendingPathComponent("target").path)
        precondition(leftovers == ["Rota.app"], "no leftover previous bundle: \(leftovers)")

        // SHA-256 of a file matches CryptoKit over the same bytes.
        let blob = scratch.appendingPathComponent("blob")
        try Data(repeating: 7, count: 3_000_000).write(to: blob)
        let expected = SHA256.hash(data: Data(repeating: 7, count: 3_000_000)).map { String(format: "%02x", $0) }.joined()
        let digest = try UpdateInstall.sha256(ofFileAt: blob)
        precondition(digest == expected)

        // The running test binary satisfies its own designated requirement; a different bundle does not.
        let requirement = try UpdateInstall.requirementOfRunningCode()
        try UpdateInstall.verify(bundle: URL(fileURLWithPath: CommandLine.arguments[0]), satisfies: requirement)
        do {
            try UpdateInstall.verify(bundle: URL(fileURLWithPath: "/System/Applications/Calculator.app"), satisfies: requirement)
            preconditionFailure("Calculator must not satisfy this binary's requirement")
        } catch UpdateInstall.Failure.signature {}

        print("UpdateChecker tests passed: version/build ordering, OS minimum, daily schedule, skip, manifest decoding, HTTPS same-host downloads, in-app install plan, swap script, checksum, signature check.")
    }
}
