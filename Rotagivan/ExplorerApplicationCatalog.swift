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
         URL(fileURLWithPath: "/System/Applications", isDirectory: true),
         URL(fileURLWithPath: "/System/Cryptexes/App/System/Applications", isDirectory: true)]
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

    static func scan() -> [ExplorerApplication] {
        scanWithStatus().applications
    }

    static func scan(roots: [URL]) -> [ExplorerApplication] {
        scanWithStatus(roots: roots).applications
    }

    static func scanWithStatus() -> ScanResult {
        scanWithStatus(roots: roots, includeFinder: true)
    }

    static func scanWithStatus(roots: [URL]) -> ScanResult {
        scanWithStatus(roots: roots, includeFinder: false)
    }

    private static func scanWithStatus(roots: [URL], includeFinder: Bool) -> ScanResult {
        let manager = FileManager.default
        var seen = Set<String>()
        var result: [ExplorerApplication] = []
        var errors: [String] = []
        if includeFinder {
            let finderURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder")
                ?? URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app", isDirectory: true)
            if let finder = application(at: finderURL) {
                seen.insert(finder.url.resolvingSymlinksInPath().path)
                result.append(finder)
            }
        }
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

struct ExplorerFolder: Identifiable, Hashable, Sendable {
    let name: String
    let url: URL
    var id: String { url.standardizedFileURL.path }
    var location: String { url.deletingLastPathComponent().path }
}

enum ExplorerFolderCatalog {
    static func roots(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        [home, home.appendingPathComponent("Desktop", isDirectory: true),
         home.appendingPathComponent("Documents", isDirectory: true),
         home.appendingPathComponent("Downloads", isDirectory: true),
         home.appendingPathComponent("Applications", isDirectory: true),
         home.appendingPathComponent("Movies", isDirectory: true),
         home.appendingPathComponent("Music", isDirectory: true),
         home.appendingPathComponent("Pictures", isDirectory: true),
         home.appendingPathComponent("Public", isDirectory: true),
         URL(fileURLWithPath: "/Applications", isDirectory: true),
         URL(fileURLWithPath: "/System/Applications", isDirectory: true)]
    }

    /// Index standard locations and one level of visible child folders; do not
    /// recurse through user data or follow symlinks while building launcher results.
    static func scan(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [ExplorerFolder] {
        let manager = FileManager.default
        var folders: [String: ExplorerFolder] = [:]
        let searchRoots = roots(home: home)
        for root in searchRoots {
            guard (try? root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let standardized = root.standardizedFileURL
            folders[standardized.path] = ExplorerFolder(
                name: standardized == home.standardizedFileURL ? "Home" : standardized.lastPathComponent,
                url: standardized)
            guard let children = try? manager.contentsOfDirectory(at: standardized,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { continue }
            for child in children {
                guard folders.count < 2_000,
                      child.pathExtension.lowercased() != "app",
                      child.lastPathComponent != "Library",
                      let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                      values.isDirectory == true, values.isSymbolicLink != true else { continue }
                let childURL = child.standardizedFileURL
                folders[childURL.path] = ExplorerFolder(name: childURL.lastPathComponent, url: childURL)
            }
        }
        return folders.values.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }
}

/// A process-local Rust index. Bundle metadata is scanned in the background by
/// VoiceApplicationIndex; queries only read this complete in-memory snapshot.
final class RustApplicationSearch: @unchecked Sendable {
    static let shared = RustApplicationSearch()
    private typealias New = @convention(c) () -> UnsafeMutableRawPointer?
    private typealias Free = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private typealias Add = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void
    private typealias Search = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafeMutablePointer<Int>?, Int) -> Int
    private let lock = NSLock()
    private var cached: [ExplorerApplication] = []
    private var index: UnsafeMutableRawPointer?
    private var library: UnsafeMutableRawPointer?
    private var create: New?
    private var destroy: Free?
    private var add: Add?
    private var query: Search?
    var isAvailable: Bool { query != nil }
    init(path: String? = nil) {
        guard let path = path ?? Bundle.main.url(forResource: "librota_search", withExtension: "dylib")?.path,
              let library = dlopen(path, RTLD_NOW | RTLD_LOCAL) else { return }
        self.library = library
        guard let n = dlsym(library, "rota_index_new"), let f = dlsym(library, "rota_index_free"),
              let a = dlsym(library, "rota_index_add"), let s = dlsym(library, "rota_index_search") else { return }
        create = unsafeBitCast(n, to: New.self); destroy = unsafeBitCast(f, to: Free.self)
        add = unsafeBitCast(a, to: Add.self); query = unsafeBitCast(s, to: Search.self)
    }
    deinit { destroy?(index); if let library { dlclose(library) } }
    private func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    func search(_ text: String, applications: [ExplorerApplication], limit: Int = 12) -> [ExplorerApplication] {
        lock.lock(); defer { lock.unlock() }
        guard let query, let create, let add else {
            return Array(ExplorerApplicationCatalog.search(text, in: applications).prefix(max(0, limit)))
        }
        if index == nil || cached != applications {
            destroy?(index); index = create(); cached = applications
            for app in cached { normalized(app.name).withCString { name in
                normalized(app.bundleID).withCString { id in add(index, name, id) }
            } }
        }
        var hits = [Int](repeating: 0, count: min(max(0, limit), cached.count))
        guard !hits.isEmpty else { return [] }
        let count = normalized(text).withCString { text in
            hits.withUnsafeMutableBufferPointer { buffer in query(index, text, buffer.baseAddress, buffer.count) }
        }
        return hits.prefix(count).compactMap { cached.indices.contains($0) ? cached[$0] : nil }
    }
}
