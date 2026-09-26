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
        guard let (id, metadata) = validatedMetadata(at: url) else { return nil }
        let display = (localizedDisplayName(at: url) ?? (metadata["CFBundleDisplayName"] as? String))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = display?.isEmpty == false ? display! : url.deletingPathExtension().lastPathComponent
        return ExplorerApplication(bundleID: id, name: name, url: url.standardizedFileURL)
    }

    /// Identity checks need fresh Info.plist data, but never enumerate Resources
    /// or read localized names. Full catalog entries reuse this same single read.
    static func bundleIdentifier(at url: URL) -> String? {
        validatedMetadata(at: url)?.identifier
    }

    private static func validatedMetadata(at url: URL) -> (identifier: String, metadata: [String: Any])? {
        guard url.isFileURL, url.pathExtension.lowercased() == "app",
              (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
              let metadata = metadata(at: url), let id = metadata["CFBundleIdentifier"] as? String,
              !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, id != "local.rotagivan" else { return nil }
        return (id, metadata)
    }

    /// Bundle caches metadata by path, which can retain the old identity after
    /// an installer atomically replaces an application. Read only its bounded
    /// property list afresh; support both standard macOS and flat bundles.
    private static func metadata(at application: URL) -> [String: Any]? {
        for relative in ["Contents/Info.plist", "Info.plist"] {
            if let metadata = propertyList(at: application.appendingPathComponent(relative)) { return metadata }
        }
        return nil
    }

    private static func propertyList(at url: URL) -> [String: Any]? {
        let file = url.resolvingSymlinksInPath()
        guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
        guard let input = InputStream(url: file) else { return nil }
        input.open(); defer { input.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = input.read(&buffer, maxLength: buffer.count)
            if count == 0 { break }
            if count < 0 || data.count + count > 1_048_576 { return nil }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard let value = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else { return nil }
        return value as? [String: Any]
    }

    private static func localizedDisplayName(at application: URL) -> String? {
        for resources in [application.appendingPathComponent("Contents/Resources"), application] {
            guard let entries = try? FileManager.default.contentsOfDirectory(at: resources,
                includingPropertiesForKeys: nil, options: .skipsHiddenFiles) else { continue }
            let localizations = entries.filter { $0.pathExtension == "lproj" }
                .map { $0.deletingPathExtension().lastPathComponent }.sorted()
            for locale in Bundle.preferredLocalizations(from: localizations) {
                let url = resources.appendingPathComponent(locale + ".lproj/InfoPlist.strings")
                if let name = propertyList(at: url)?["CFBundleDisplayName"] as? String,
                   !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return name }
            }
        }
        return nil
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
            // An explicitly selected application root may be a symlink (for
            // example ~/Applications on another volume). Traverse its target,
            // while still skipping symlinked descendants below that root.
            let scanRoot = root.resolvingSymlinksInPath()
            // A user Applications directory is optional. Other read failures are surfaced.
            do { _ = try scanRoot.resourceValues(forKeys: [.isDirectoryKey]) }
            catch {
                if (error as NSError).code != NSFileReadNoSuchFileError {
                    errors.append("Could not read \(root.path): \(error.localizedDescription)")
                }
                continue
            }
            guard let walker = manager.enumerator(at: scanRoot, includingPropertiesForKeys: [.isSymbolicLinkKey],
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
           bundleIdentifier(at: URL(fileURLWithPath: path)) == bundleID {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }
}
