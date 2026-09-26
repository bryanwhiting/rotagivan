import AppKit

struct ExplorerApplication: Identifiable, Hashable, Sendable {
    let bundleID: String
    let name: String
    let url: URL
    var id: String { url.path }
    var location: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path + "/"
        let parent = url.deletingLastPathComponent().path
        return parent.hasPrefix(home) ? "~/" + parent.dropFirst(home.count) : parent
    }
}

enum ExplorerApplicationCatalog {
    struct ScanResult: Sendable {
        let applications: [ExplorerApplication]
        let errors: [String]
    }
    static var roots: [URL] {
        [URL(fileURLWithPath: "/Applications", isDirectory: true),
         FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
         URL(fileURLWithPath: "/System/Applications", isDirectory: true)]
    }

    static func application(at url: URL) -> ExplorerApplication? {
        guard url.isFileURL, url.pathExtension.lowercased() == "app",
              (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
              let bundle = Bundle(url: url), let id = bundle.bundleIdentifier,
              !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, id != "local.rotagivan" else { return nil }
        let display = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = display?.isEmpty == false ? display! : url.deletingPathExtension().lastPathComponent
        return ExplorerApplication(bundleID: id, name: name, url: url.standardizedFileURL)
    }

    static func scan(roots: [URL] = Self.roots) -> [ExplorerApplication] {
        scanWithStatus(roots: roots).applications
    }

    static func scanWithStatus(roots: [URL] = Self.roots) -> ScanResult {
        let manager = FileManager.default
        var seen = Set<String>()
        var result: [ExplorerApplication] = []
        var errors: [String] = []
        for root in roots {
            // A user Applications directory is optional. Other read failures are surfaced.
            do { _ = try root.resourceValues(forKeys: [.isDirectoryKey]) }
            catch {
                if (error as NSError).code != NSFileReadNoSuchFileError {
                    errors.append("Could not read \(root.path): \(error.localizedDescription)")
                }
                continue
            }
            guard let walker = manager.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { url, error in
                    if errors.count < 5 { errors.append("Could not read \(url.path): \(error.localizedDescription)") }
                    return true
                }) else {
                errors.append("Could not enumerate \(root.path).")
                continue
            }
            for case let url as URL in walker {
                if url.pathExtension.lowercased() == "app" {
                    walker.skipDescendants() // Never expose an app's embedded helper apps.
                    if let app = application(at: url), seen.insert(url.resolvingSymlinksInPath().path).inserted {
                        result.append(app)
                    }
                } else if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                    walker.skipDescendants()
                }
            }
        }
        return ScanResult(applications: result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
                          errors: errors)
    }

    static func search(_ query: String, in applications: [ExplorerApplication]) -> [ExplorerApplication] {
        let tokens = normalized(query).split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return applications.compactMap { app -> (ExplorerApplication, Int)? in
            var score = 0
            for token in tokens {
                let nameScore = fuzzyScore(token, in: normalized(app.name))
                let idScore = fuzzyScore(token, in: normalized(app.bundleID)).map { $0 - 250 }
                guard let best = [nameScore, idScore].compactMap({ $0 }).max() else { return nil }
                score += best
            }
            return (app, score)
        }.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            let order = $0.0.name.localizedStandardCompare($1.0.name)
            return order == .orderedSame ? $0.0.id < $1.0.id : order == .orderedAscending
        }.map(\.0)
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func fuzzyScore(_ needle: String, in haystack: String) -> Int? {
        if needle == haystack { return 10_000 }
        if haystack.hasPrefix(needle) { return 8_000 - haystack.count }
        if haystack.contains(needle) { return 6_000 - haystack.count }
        let characters = Array(haystack)
        var index = 0, previous = -2, score = 1_000
        for character in needle {
            guard let found = characters[index...].firstIndex(of: character) else { return nil }
            score += found == previous + 1 ? 60 : 0
            if found == 0 || !characters[found - 1].isLetter { score += 80 }
            score -= found - index
            previous = found; index = found + 1
        }
        return score - characters.count
    }

    // This machine-specific hint is deliberately outside the synced configuration.
    static func remember(_ app: ExplorerApplication, defaults: UserDefaults = .standard) {
        var paths = defaults.dictionary(forKey: "appExplorer.localApplicationPaths") as? [String: String] ?? [:]
        paths[app.bundleID] = app.url.path
        defaults.set(paths, forKey: "appExplorer.localApplicationPaths")
    }

    static func applicationURL(for bundleID: String, defaults: UserDefaults = .standard) -> URL? {
        if let path = (defaults.dictionary(forKey: "appExplorer.localApplicationPaths") as? [String: String])?[bundleID],
           let app = application(at: URL(fileURLWithPath: path)), app.bundleID == bundleID {
            return app.url
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }
}
