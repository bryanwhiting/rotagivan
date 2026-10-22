import Foundation

enum BrowserBookmarkSource: String, CaseIterable, Identifiable, Sendable {
    case chrome
    case safari

    var id: String { rawValue }
    var title: String { self == .chrome ? "Chrome" : "Safari" }
    var symbol: String { self == .chrome ? "globe" : "safari" }
    var fileName: String { self == .chrome ? "Bookmarks" : "Bookmarks.plist" }
}

struct BrowserBookmark: Identifiable, Hashable, Sendable {
    let source: BrowserBookmarkSource
    let title: String
    let url: URL
    let folder: String
    let profile: String?

    var id: String { source.rawValue + "|" + url.absoluteString }
    var location: String {
        [profile, folder.isEmpty ? nil : folder].compactMap { $0 }.joined(separator: " · ")
    }
}

enum BrowserBookmarkImportError: LocalizedError {
    case unavailable(BrowserBookmarkSource)
    case unreadable(String)
    case oversized
    case invalid(BrowserBookmarkSource)

    var errorDescription: String? {
        switch self {
        case .unavailable(let source):
            return "No \(source.title) bookmark file was found. You can choose \(source.fileName) manually."
        case .unreadable(let detail):
            return "Bookmarks could not be read. \(detail)"
        case .oversized:
            return "That bookmark file is too large to import safely."
        case .invalid(let source):
            return "That file is not a valid \(source.title) bookmark export."
        }
    }
}

enum BrowserBookmarkLoader {
    static let maximumFileSize = 64 * 1_024 * 1_024
    static let maximumBookmarks = 10_000

    static func suggestedDirectory(for source: BrowserBookmarkSource) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch source {
        case .chrome:
            return home.appendingPathComponent("Library/Application Support/Google/Chrome", isDirectory: true)
        case .safari:
            return home.appendingPathComponent("Library/Safari", isDirectory: true)
        }
    }

    static func load(_ source: BrowserBookmarkSource, from selectedFile: URL? = nil) throws -> [BrowserBookmark] {
        if let selectedFile {
            let data = try safeData(at: selectedFile)
            switch source {
            case .chrome:
                return try parseChrome(data, profile: selectedFile.deletingLastPathComponent().lastPathComponent)
            case .safari:
                return try parseSafari(data)
            }
        }
        switch source {
        case .safari:
            let file = suggestedDirectory(for: .safari).appendingPathComponent("Bookmarks.plist")
            guard FileManager.default.fileExists(atPath: file.path) else { throw BrowserBookmarkImportError.unavailable(.safari) }
            return try parseSafari(safeData(at: file))
        case .chrome:
            let root = suggestedDirectory(for: .chrome)
            guard let folders = try? FileManager.default.contentsOfDirectory(at: root,
                includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
                throw BrowserBookmarkImportError.unavailable(.chrome)
            }
            let profiles = folders.filter {
                let name = $0.lastPathComponent
                return name == "Default" || name.hasPrefix("Profile ")
            }.sorted { lhs, rhs in
                if lhs.lastPathComponent == "Default" { return true }
                if rhs.lastPathComponent == "Default" { return false }
                return lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
            }
            var result: [BrowserBookmark] = []
            var sawFile = false
            for profile in profiles {
                let file = profile.appendingPathComponent("Bookmarks")
                guard FileManager.default.fileExists(atPath: file.path) else { continue }
                sawFile = true
                result += (try? parseChrome(safeData(at: file), profile: profile.lastPathComponent)) ?? []
                if result.count >= maximumBookmarks { break }
            }
            guard sawFile else { throw BrowserBookmarkImportError.unavailable(.chrome) }
            return deduplicated(Array(result.prefix(maximumBookmarks)))
        }
    }

    static func parseChrome(_ data: Data, profile: String? = nil) throws -> [BrowserBookmark] {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any], let roots = root["roots"] as? [String: Any] else {
            throw BrowserBookmarkImportError.invalid(.chrome)
        }
        var result: [BrowserBookmark] = []
        func walk(_ value: Any, path: [String], depth: Int) {
            guard result.count < maximumBookmarks, depth <= 32, let node = value as? [String: Any] else { return }
            let type = node["type"] as? String
            let rawName = (node["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if type == "url", let rawURL = node["url"] as? String,
               let url = AppExplorerFavorite.webURL(rawURL) {
                let name = sanitizedTitle(rawName, url: url)
                result.append(BrowserBookmark(source: .chrome, title: name, url: url,
                    folder: path.joined(separator: " / "), profile: profile))
                return
            }
            guard let children = node["children"] as? [Any] else { return }
            let nextPath = rawName.isEmpty ? path : path + [rawName]
            for child in children { walk(child, path: nextPath, depth: depth + 1) }
        }
        for key in ["bookmark_bar", "other", "synced"] {
            if let node = roots[key] { walk(node, path: [], depth: 0) }
        }
        return deduplicated(result)
    }

    static func parseSafari(_ data: Data) throws -> [BrowserBookmark] {
        guard let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              object is [String: Any] else { throw BrowserBookmarkImportError.invalid(.safari) }
        var result: [BrowserBookmark] = []
        func walk(_ value: Any, path: [String], depth: Int) {
            guard result.count < maximumBookmarks, depth <= 32, let node = value as? [String: Any] else { return }
            if let rawURL = node["URLString"] as? String, let url = AppExplorerFavorite.webURL(rawURL) {
                let uri = node["URIDictionary"] as? [String: Any]
                let rawName = (uri?["title"] as? String) ?? (node["Title"] as? String) ?? ""
                result.append(BrowserBookmark(source: .safari, title: sanitizedTitle(rawName, url: url),
                    url: url, folder: path.joined(separator: " / "), profile: nil))
            }
            guard let children = node["Children"] as? [Any] else { return }
            let rawFolder = (node["Title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let hiddenRoots = ["Bookmarks", "Root", "com.apple.ReadingList"]
            let nextPath = rawFolder.isEmpty || hiddenRoots.contains(rawFolder) ? path : path + [rawFolder]
            for child in children { walk(child, path: nextPath, depth: depth + 1) }
        }
        walk(object, path: [], depth: 0)
        return deduplicated(result)
    }

    private static func safeData(at url: URL) throws -> Data {
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { throw BrowserBookmarkImportError.unreadable("Choose a regular bookmark file.") }
            guard (values.fileSize ?? 0) <= maximumFileSize else { throw BrowserBookmarkImportError.oversized }
            return try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch let error as BrowserBookmarkImportError { throw error }
        catch { throw BrowserBookmarkImportError.unreadable(error.localizedDescription) }
    }

    private static func sanitizedTitle(_ raw: String, url: URL) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((value.isEmpty ? (url.host ?? "Website") : value).prefix(512))
    }

    private static func deduplicated(_ values: [BrowserBookmark]) -> [BrowserBookmark] {
        var seen = Set<String>()
        return values.filter { seen.insert($0.url.absoluteString).inserted }
    }
}
