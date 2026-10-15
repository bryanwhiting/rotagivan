import Foundation

@main struct AppVersionTests {
    static func main() throws {
        let hash = "ABCD" + String(repeating: "E", count: 36)
        let info: [String: Any] = ["CFBundleShortVersionString": "1.2.3", "CFBundleVersion": "45",
            "RotagivanGitCommit": hash, "RotagivanGitDirty": false,
            "RotagivanSourceInputSHA256": String(repeating: "a", count: 64),
            "RotagivanBuildDateUTC": "2026-10-15T00:00:00+00:00"]
        let clean = AppVersion.Metadata(info: info)
        precondition(clean.versionLabel == "v1.2.3-abcd")
        precondition(clean.display == "v1.2.3-abcd (45)")
        precondition(clean.version == "1.2.3" && clean.build == "45")
        precondition(clean.buildDetails.contains(hash.lowercased()))
        precondition(clean.buildDetails.contains("Clean:"))
        var dirtyInfo = info
        dirtyInfo["RotagivanGitDirty"] = true
        let dirty = AppVersion.Metadata(info: dirtyInfo)
        precondition(dirty.versionLabel == "v1.2.3-abcd-dirty")
        precondition(dirty.buildDetails.contains("commit identifies the base revision"))
        for invalid in ["", "abcd", "not-a-hash", String(repeating: "z", count: 40)] {
            var invalidInfo = info
            invalidInfo["RotagivanGitCommit"] = invalid
            let unknown = AppVersion.Metadata(info: invalidInfo)
            precondition(unknown.versionLabel == "v1.2.3-unknown")
            precondition(unknown.commit == nil && unknown.buildDetails.contains("Git commit: unknown"))
        }
        var unknownState = info
        unknownState.removeValue(forKey: "RotagivanGitDirty")
        precondition(AppVersion.Metadata(info: unknownState).versionLabel == "v1.2.3-abcd-unknown")
        var sha256Info = info
        sha256Info["RotagivanGitCommit"] = String(repeating: "e", count: 64)
        precondition(AppVersion.Metadata(info: sha256Info).versionLabel == "v1.2.3-eeee")
        precondition(AppVersion.Metadata(info: [:]).display == "vDevelopment-unknown (—)")
        if CommandLine.arguments.count > 1 {
            let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
            let installed = try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
            let actual = AppVersion.Metadata(info: installed)
            precondition(actual.versionLabel == installed["RotagivanDisplayVersion"] as? String)
            precondition(actual.commit != nil && actual.dirty != nil)
            print("Installed metadata display: \(actual.display)\n\(actual.buildDetails)")
        }
        print("AppVersion tests passed: clean/dirty, lowercase short/full SHA, numeric fields, unknown and installed metadata.")
    }
}
