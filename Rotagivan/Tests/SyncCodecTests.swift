import Foundation

/// Field-journal ↔ configuration codec. Dummy configurations only.
@main struct SyncCodecTests {
    static func main() throws {
        let base = try AppConfiguration.parse(String(contentsOfFile: "Rotagivan/DefaultConfiguration.yaml", encoding: .utf8))
        var config = base
        config.profiles = [ConfigurationProfile(id: "a", name: "Alpha", settings: base.settings, shortcuts: base.shortcuts),
                           ConfigurationProfile(id: "b", name: "Beta", settings: base.settings, shortcuts: base.shortcuts)]
        config.activeConfigurationID = "b"
        let fields = try SyncConfigurationCodec.fields(config)
        precondition(fields["[\"settings\"]"] == nil && fields["[\"shortcuts\"]"] == nil,
                     "Profiles carry a single authoritative copy of settings and shortcuts")
        var journal = EncryptedSettingsJournal()
        for (name, value) in fields.sorted(by: { $0.key < $1.key }) { try journal.set(value, for: name, deviceID: "mac-a") }
        let rebuilt = try SyncConfigurationCodec.configuration(journal)!
        let rebuiltFingerprint = try rebuilt.syncFingerprint(), configFingerprint = try config.syncFingerprint()
        precondition(rebuiltFingerprint == configFingerprint, "Journal round-trips the configuration")
        precondition(rebuilt.profiles?.map(\.id) == ["a", "b"] && rebuilt.activeConfigurationID == "b")

        // Mac A deletes profile "b" (tombstones) while Mac B's newer edit to one
        // field inside "b" wins its per-field race. The orphan fragment is not a
        // profile: the deletion stands and the active profile falls back.
        var deleted = journal
        for name in fields.keys.sorted() where name.hasPrefix("[\"profiles\",\"b\"") { try deleted.set(nil, for: name, deviceID: "mac-a") }
        try deleted.set(try JSONSerialization.data(withJSONObject: ["a"], options: [.fragmentsAllowed]), for: "[\"profileOrder\"]", deviceID: "mac-a")
        var edited = journal
        for _ in 0..<(fields.count + 4) {
            try edited.set(Data("0.75".utf8), for: "[\"profiles\",\"b\",\"settings\",\"normal\",\"cursorSpeed\"]", deviceID: "mac-b")
        }
        var merged = deleted
        try merged.merge(edited)
        precondition(merged.fields["[\"profiles\",\"b\",\"settings\",\"normal\",\"cursorSpeed\"]"]?.value != nil, "Fixture: the edit must outrank the tombstone")
        precondition(merged.fields["[\"profiles\",\"b\",\"name\"]"]?.value == nil)
        let survivor = try SyncConfigurationCodec.configuration(merged)!
        precondition(survivor.profiles?.map(\.id) == ["a"], "A fragment of a deleted profile is dropped, not decoded")
        precondition(survivor.activeConfigurationID == "a")
        try survivor.validate()
        // Re-reading the survivor as fields never resurrects the fragment.
        let again = try SyncConfigurationCodec.fields(survivor)
        precondition(!again.keys.contains { $0.hasPrefix("[\"profiles\",\"b\"") })

        // Removing every profile fails closed rather than inventing defaults.
        var none = merged
        for name in fields.keys.sorted() where name.hasPrefix("[\"profiles\",\"a\"") { try none.set(nil, for: name, deviceID: "mac-a") }
        do { _ = try SyncConfigurationCodec.configuration(none); preconditionFailure("Expected rejection") } catch {}
        print("Sync codec PASS: profile-keyed round trip, orphan profile fragment dropped after a delete/edit race, empty library rejected")
    }
}
