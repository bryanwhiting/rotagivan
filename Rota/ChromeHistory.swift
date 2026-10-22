import Foundation
import SQLite3

/// One row of Chrome's `urls` table, as shown in the typing launcher.
struct ChromeHistoryEntry: Hashable, Sendable {
    let url: String
    let title: String
    let lastVisit: Date
    let visitCount: Int
    var host: String { URLComponents(string: url)?.host ?? "" }
    /// Chrome stores microseconds since 1601-01-01 (Windows FILETIME epoch).
    static func date(chromeTime: Int64) -> Date {
        Date(timeIntervalSince1970: Double(chromeTime) / 1_000_000 - 11_644_473_600)
    }
}

/// Opt-in launcher index of recently visited Chrome pages. Chrome keeps its
/// History SQLite file locked while it runs, so each refresh copies the file
/// (and its journal) to a private temporary directory and opens that copy
/// read-only. Nothing is read while the setting is off, and no history row is
/// written to disk by Rota or included in settings sync.
actor ChromeHistoryIndex {
    static let shared = ChromeHistoryIndex()
    static let maximumEntries = 3000
    static let refreshInterval: TimeInterval = 120
    static let staleAfter: TimeInterval = 30
    /// Each profile is read a little deeper than the final bound so that the
    /// site-prefix deduplication across profiles still fills the list.
    static let rowsPerProfile = 6000

    private(set) var entries: [ChromeHistoryEntry] = []
    private(set) var lastRefresh: Date?
    private var enabled = false
    private var periodic: Task<Void, Never>?
    private var refresh: Task<[ChromeHistoryEntry], Never>?
    private let profileRoot: URL
    private let interval: TimeInterval

    init(profileRoot: URL = ChromeLocalHistory.profileRoot, interval: TimeInterval = ChromeHistoryIndex.refreshInterval) {
        self.profileRoot = profileRoot
        self.interval = interval
    }

    var isEnabled: Bool { enabled }

    /// The General settings toggle and the launcher both route through here;
    /// turning the feature off cancels the periodic read and drops the cache.
    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        if on {
            periodic = Task { [weak self, interval] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                    guard !Task.isCancelled, let self else { return }
                    _ = await self.refreshNow()
                }
            }
        } else {
            periodic?.cancel(); periodic = nil
            refresh?.cancel(); refresh = nil
            entries = []; lastRefresh = nil
        }
    }

    /// The cached list, refreshed first when it is older than `maxAge`. Called
    /// when the launcher opens; the caller shows its previous rows meanwhile.
    func snapshot(maxAge: TimeInterval = ChromeHistoryIndex.staleAfter) async -> [ChromeHistoryEntry] {
        guard enabled else { return [] }
        if let lastRefresh, Date().timeIntervalSince(lastRefresh) < maxAge { return entries }
        return await refreshNow()
    }

    /// Reads every profile off the actor's executor; concurrent callers share one read.
    @discardableResult func refreshNow() async -> [ChromeHistoryEntry] {
        guard enabled else { return [] }
        if let refresh { return await refresh.value }
        let root = profileRoot
        let task = Task.detached(priority: .utility) { Self.load(profileRoot: root) }
        refresh = task
        let loaded = await task.value
        refresh = nil
        guard enabled, !task.isCancelled else { return entries }
        entries = loaded
        lastRefresh = Date()
        return loaded
    }

    // MARK: - Reading

    /// Every Chrome profile directory that has a History file, merged, deduped
    /// by site prefix, newest first, bounded to `limit` rows.
    static func load(profileRoot: URL, limit: Int = maximumEntries) -> [ChromeHistoryEntry] {
        guard let profiles = try? FileManager.default.contentsOfDirectory(at: profileRoot,
                  includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        var lists: [[ChromeHistoryEntry]] = []
        for profile in profiles.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where profile.lastPathComponent == "Default" || profile.lastPathComponent.hasPrefix("Profile ") {
            let history = profile.appendingPathComponent("History")
            guard FileManager.default.fileExists(atPath: history.path) else { continue }
            if let rows = read(historyFile: history, limit: rowsPerProfile) { lists.append(rows) }
        }
        return merged(lists, limit: limit)
    }

    /// Copies the History file (plus a rollback journal or WAL if present) to a
    /// temporary directory and queries the copy. The copy is private, so it is
    /// opened read-write: SQLite can then roll back a journal that was caught
    /// mid-transaction instead of refusing the read. The copy is removed before
    /// returning; Chrome's own files are never opened.
    static func read(historyFile: URL, limit: Int) -> [ChromeHistoryEntry]? {
        let manager = FileManager.default
        let scratch = manager.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("rota-chrome-history-" + UUID().uuidString, isDirectory: true)
        guard (try? manager.createDirectory(at: scratch, withIntermediateDirectories: true,
                   attributes: [.posixPermissions: 0o700])) != nil else { return nil }
        defer { try? manager.removeItem(at: scratch) }
        let copy = scratch.appendingPathComponent("History")
        guard (try? manager.copyItem(at: historyFile, to: copy)) != nil else { return nil }
        for suffix in ["-journal", "-wal"] {
            let sidecar = URL(fileURLWithPath: historyFile.path + suffix)
            if manager.fileExists(atPath: sidecar.path) {
                try? manager.copyItem(at: sidecar, to: URL(fileURLWithPath: copy.path + suffix))
            }
        }
        return query(copy, limit: limit)
    }

    private static func query(_ file: URL, limit: Int) -> [ChromeHistoryEntry]? {
        var database: OpaquePointer?
        // The copy sits in a private directory created moments ago, so no
        // NOFOLLOW: macOS's temporary path itself goes through the /var symlink.
        guard sqlite3_open_v2(file.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let database else { if database != nil { sqlite3_close(database) }; return nil }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 100)
        let sql = """
            SELECT url, title, last_visit_time, visit_count FROM urls
            WHERE hidden = 0 AND (url LIKE 'http://%' OR url LIKE 'https://%')
            ORDER BY last_visit_time DESC LIMIT ?
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { if statement != nil { sqlite3_finalize(statement) }; return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(max(0, limit)))
        var rows: [ChromeHistoryEntry] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            if let urlText = sqlite3_column_text(statement, 0) {
                let url = String(cString: urlText)
                let title = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
                rows.append(ChromeHistoryEntry(url: url,
                    title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                    lastVisit: ChromeHistoryEntry.date(chromeTime: sqlite3_column_int64(statement, 2)),
                    visitCount: Int(sqlite3_column_int(statement, 3))))
            }
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { return nil }
        return rows
    }

    /// One row per site prefix (scheme, host and path; query and fragment
    /// dropped), keeping the newest visit and the summed visit count.
    static func merged(_ lists: [[ChromeHistoryEntry]], limit: Int = maximumEntries) -> [ChromeHistoryEntry] {
        var byPrefix: [String: ChromeHistoryEntry] = [:]
        for entry in lists.joined() where !entry.url.isEmpty {
            let key = ChromeBookmarkTabs.sitePrefix(entry.url)
            if let old = byPrefix[key] {
                let newest = entry.lastVisit > old.lastVisit ? entry : old
                byPrefix[key] = ChromeHistoryEntry(url: newest.url,
                    title: newest.title.isEmpty ? (entry.title.isEmpty ? old.title : entry.title) : newest.title,
                    lastVisit: newest.lastVisit, visitCount: old.visitCount + entry.visitCount)
            } else {
                byPrefix[key] = entry
            }
        }
        return Array(byPrefix.values.sorted { lhs, rhs in
            lhs.lastVisit == rhs.lastVisit ? lhs.url < rhs.url : lhs.lastVisit > rhs.lastVisit
        }.prefix(max(0, limit)))
    }
}
