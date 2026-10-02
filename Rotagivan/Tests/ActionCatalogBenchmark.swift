import Foundation

/// Synthetic, optimized-build baseline. Never reads apps, credentials, or user settings.
@main struct ActionCatalogBenchmark {
    static func main() throws {
        var results: [[String: Any]] = []
        var checksum = 0
        for (appCount, macroCount) in [(100, 0), (300, 100), (1000, 500)] {
            var settings = StoredSettings()
            settings.hotkeyDictionary = (0..<macroCount).map { index in
                NamedHotkey(name: "Synthetic macro \(index)", shortcut:
                    RecordedShortcut(keyCode: 8, modifiers: 1 << 20, keyLabel: "C"))
            }
            let apps = (0..<appCount).map { index in
                ExplorerApplication(bundleID: "benchmark.app.\(index)", name: "Synthetic app \(index)",
                    url: URL(fileURLWithPath: "/synthetic/Application\(index).app"))
            }
            let keys = ShortcutConfiguration()
            let audit = HotkeyAudit(settings: settings, shortcuts: keys, layerID: 1, device: .navigator)
            func measure(_ name: String, _ work: () -> Int) {
                checksum &+= work() // Warm up locale and runtime initialization.
                var milliseconds: [Double] = []
                for _ in 0..<12 {
                    let start = DispatchTime.now().uptimeNanoseconds
                    checksum &+= work()
                    milliseconds.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
                }
                milliseconds.sort()
                results.append(["operation": name, "applications": appCount, "macros": macroCount,
                    "samples": milliseconds.count, "median_ms": milliseconds[milliseconds.count / 2],
                    "p95_ms": milliseconds[Int(ceil(Double(milliseconds.count) * 0.95)) - 1]])
            }
            measure("audit") {
                let value = HotkeyAudit(settings: settings, shortcuts: keys, layerID: 1, device: .navigator)
                return value.assignments.count + value.findings.count
            }
            measure("voice_registry") {
                VoiceActionRegistry.make(settings: settings, applications: apps,
                    includeInactiveApplications: true).count
            }
            measure("action_table") {
                ActionTableRow.make(settings: settings, applications: apps, audit: audit).count
            }
            let snapshot = ActionCatalogValue.build(ActionCatalogInput(settings: settings, shortcuts: keys,
                applications: apps, layerID: 1, device: .navigator))
            measure("cached_search") {
                snapshot.filtered(group: "All groups", subgroup: "All subgroups", search: "synthetic app 9").count
            }
        }
        let output: [String: Any] = ["fixture": "synthetic-v1", "checksum": checksum,
            "optimized": true, "results": results]
        let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
