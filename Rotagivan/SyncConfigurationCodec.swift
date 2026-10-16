import Foundation

/// Scalars merge independently. Ordered lists stay atomic so commands, macro
/// steps, and hotkey ordering cannot be scrambled by a concurrent edit.
enum SyncConfigurationCodec {
    private static func canonical(_ value: Any, key: String = "") -> Any {
        if let object = value as? [String: Any] {
            return object.reduce(into: [String: Any]()) { result, entry in
                result[entry.key] = canonical(entry.value, key: entry.key)
            }
        }
        if let values = value as? [Any] {
            if ["profileGestures", "appleLayerGestures", "sliderBaselines", "additional", "profileActions", "profileNames"].contains(key), values.count % 2 == 0 {
                return stride(from: 0, to: values.count, by: 2)
                    .map { (values[$0], canonical(values[$0 + 1])) }
                    .sorted { String(describing: $0.0) < String(describing: $1.0) }
                    .flatMap { [$0.0, $0.1] }
            }
            if ["customTapProfiles", "removedLayerIDs"].contains(key) {
                return values.sorted { String(describing: $0) < String(describing: $1) }
            }
            return values.map { canonical($0) }
        }
        return value
    }
    static func fields(_ config: AppConfiguration) throws -> [String: Data] {
        var config = config
        config.settings.enabled = true; config.settings.launchAtLogin = false
        config.profiles = config.profiles?.map { profile in
            var copy = profile
            copy.settings.enabled = true; copy.settings.launchAtLogin = false
            return copy
        }
        var result: [String: Data] = [:]
        func visit(_ value: Any, _ path: [String]) throws {
            if let object = value as? [String: Any], !object.isEmpty {
                for key in object.keys.sorted() { try visit(object[key]!, path + [key]) }
            } else {
                let name = String(data: try JSONEncoder().encode(path), encoding: .utf8)!
                result[name] = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
            }
        }
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as! [String: Any]
        if let profiles = object["profiles"] as? [[String: Any]], !profiles.isEmpty {
            // The active profile's settings/shortcuts are duplicated in the
            // export model. Sync a single authoritative copy of each profile.
            object.removeValue(forKey: "settings"); object.removeValue(forKey: "shortcuts")
            object["profileOrder"] = profiles.compactMap { $0["id"] as? String }
            object["profiles"] = Dictionary(uniqueKeysWithValues: profiles.map { ($0["id"] as! String, $0) })
        }
        try visit(canonical(object), [])
        return result
    }
    static func configuration(_ journal: EncryptedSettingsJournal) throws -> AppConfiguration? {
        var root: [String: Any] = [:]
        func insert(_ value: Any, path: ArraySlice<String>, into object: inout [String: Any]) throws {
            guard let first = path.first else { throw EncryptedSettingsError.invalidEnvelope }
            if path.count == 1 { object[first] = value; return }
            var child = object[first] as? [String: Any] ?? [:]
            try insert(value, path: path.dropFirst(), into: &child)
            object[first] = child
        }
        for (name, field) in journal.fields.sorted(by: { $0.key < $1.key }) {
            guard let data = field.value else { continue }
            let path = try JSONDecoder().decode([String].self, from: Data(name.utf8))
            try insert(JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed), path: path[...], into: &root)
        }
        guard !root.isEmpty else { return nil }
        if var profiles = root["profiles"] as? [String: [String: Any]], !profiles.isEmpty {
            // A profile deleted on one Mac leaves tombstones for every field; a
            // concurrent edit on another Mac can resurrect a single orphan field.
            // Such a fragment is not a profile. Treat the deletion as final rather
            // than failing to decode (which would stall every Mac's sync).
            profiles = profiles.filter { id, profile in
                profile["id"] as? String == id && profile["name"] != nil &&
                    profile["settings"] is [String: Any] && profile["shortcuts"] is [String: Any]
            }
            root["profiles"] = profiles
        }
        if let profiles = root["profiles"] as? [String: [String: Any]], !profiles.isEmpty {
            let savedOrder = root.removeValue(forKey: "profileOrder") as? [String] ?? []
            let order = savedOrder.filter { profiles[$0] != nil } + profiles.keys.filter { !savedOrder.contains($0) }.sorted()
            let selected = root["activeConfigurationID"] as? String ?? ""
            let activeID = profiles[selected] == nil ? order[0] : selected
            let active = profiles[activeID]!
            root["activeConfigurationID"] = activeID
            root["profiles"] = order.compactMap { profiles[$0] }
            root["settings"] = active["settings"]; root["shortcuts"] = active["shortcuts"]
        }
        let config = try JSONDecoder().decode(AppConfiguration.self, from: JSONSerialization.data(withJSONObject: root))
        try config.validate()
        return config
    }
    static func changes(from old: [String: Data], to new: [String: Data]) -> [String: Data?] {
        var result: [String: Data?] = [:]
        for key in Set(old.keys).union(new.keys) where old[key] != new[key] { result[key] = .some(new[key]) }
        return result
    }
}
