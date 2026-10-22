import Foundation
import SQLite3

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

/// Chrome's `urls` schema (the columns the index reads) plus fixture rows.
private func makeHistory(at profile: URL, rows: [(url: String, title: String, visits: Int, chromeTime: Int64, hidden: Int)]) throws {
    try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
    var db: OpaquePointer?
    require(sqlite3_open(profile.appendingPathComponent("History").path, &db) == SQLITE_OK, "fixture open")
    require(sqlite3_exec(db, """
        CREATE TABLE urls(id INTEGER PRIMARY KEY AUTOINCREMENT, url LONGVARCHAR, title LONGVARCHAR,
            visit_count INTEGER DEFAULT 0 NOT NULL, typed_count INTEGER DEFAULT 0 NOT NULL,
            last_visit_time INTEGER NOT NULL, hidden INTEGER DEFAULT 0 NOT NULL);
        CREATE TABLE visits(id INTEGER PRIMARY KEY, url INTEGER NOT NULL, visit_time INTEGER NOT NULL);
        """, nil, nil, nil) == SQLITE_OK, "fixture schema")
    for row in rows {
        var statement: OpaquePointer?
        require(sqlite3_prepare_v2(db, "INSERT INTO urls(url, title, visit_count, last_visit_time, hidden) VALUES (?, ?, ?, ?, ?)", -1, &statement, nil) == SQLITE_OK, "fixture insert prepare")
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, row.url, -1, transient)
        sqlite3_bind_text(statement, 2, row.title, -1, transient)
        sqlite3_bind_int(statement, 3, Int32(row.visits))
        sqlite3_bind_int64(statement, 4, row.chromeTime)
        sqlite3_bind_int(statement, 5, Int32(row.hidden))
        require(sqlite3_step(statement) == SQLITE_DONE, "fixture insert")
        sqlite3_finalize(statement)
    }
    sqlite3_close(db)
}

/// Microseconds since 1601 for a Unix timestamp, the way Chrome stores time.
private func chromeTime(_ unix: TimeInterval) -> Int64 { Int64((unix + 11_644_473_600) * 1_000_000) }

@main struct ChromeHistoryTests {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rota-chrome-history-tests-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let base: TimeInterval = 1_700_000_000
        try makeHistory(at: root.appendingPathComponent("Default"), rows: [
            ("https://github.com/rota/app?tab=readme", "Rota app · GitHub", 4, chromeTime(base + 100), 0),
            ("https://github.com/rota/app?tab=issues", "Issues · Rota", 2, chromeTime(base + 300), 0),
            ("https://mail.google.com/mail/u/0/#inbox", "Inbox (3) - Gmail", 40, chromeTime(base + 200), 0),
            ("https://secret.example.com/hidden", "Hidden row", 9, chromeTime(base + 900), 1),
            ("chrome://settings/", "Settings", 3, chromeTime(base + 800), 0),
            ("file:///Users/someone/notes.html", "Notes", 1, chromeTime(base + 700), 0),
            ("https://untitled.example.com/page", "", 1, chromeTime(base + 50), 0)
        ])
        try makeHistory(at: root.appendingPathComponent("Profile 2"), rows: [
            ("https://github.com/rota/app", "", 7, chromeTime(base + 10), 0),
            ("https://docs.example.com/guide", "Guide", 1, chromeTime(base + 400), 0)
        ])
        try makeHistory(at: root.appendingPathComponent("System Profile"), rows: [
            ("https://ignored.example.com/", "Not a user profile", 1, chromeTime(base + 999), 0)
        ])
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Profile 9"), withIntermediateDirectories: true)

        // Loading merges every user profile, drops hidden and non-web rows,
        // collapses query variants of one page, and orders newest first.
        let entries = ChromeHistoryIndex.load(profileRoot: root)
        require(entries.map(\.url) == [
            "https://docs.example.com/guide",
            "https://github.com/rota/app?tab=issues",
            "https://mail.google.com/mail/u/0/#inbox",
            "https://untitled.example.com/page"
        ], "unexpected rows: \(entries.map(\.url))")
        let github = entries[1]
        require(github.title == "Issues · Rota" && github.visitCount == 13, "newest title wins and visits are summed across variants and profiles: \(github)")
        require(abs(github.lastVisit.timeIntervalSince1970 - (base + 300)) < 0.001, "Chrome epoch conversion: \(github.lastVisit.timeIntervalSince1970)")
        require(github.host == "github.com" && entries[2].host == "mail.google.com", "host comes from the URL")
        require(ChromeHistoryIndex.load(profileRoot: root, limit: 2).count == 2, "the list is bounded")
        require(ChromeHistoryIndex.load(profileRoot: root.appendingPathComponent("missing")).isEmpty, "a missing Chrome directory reads as empty")
        let scratchLeftovers = (try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path))?
            .filter { $0.hasPrefix("rota-chrome-history-") && !$0.hasPrefix("rota-chrome-history-tests-") } ?? []
        require(scratchLeftovers.isEmpty, "temporary History copies are removed: \(scratchLeftovers)")

        // Chrome holds its History file locked while running; the copy still reads.
        var locked: OpaquePointer?
        let defaultHistory = root.appendingPathComponent("Default/History")
        require(sqlite3_open(defaultHistory.path, &locked) == SQLITE_OK && sqlite3_exec(locked, "BEGIN EXCLUSIVE", nil, nil, nil) == SQLITE_OK, "lock fixture")
        var direct: OpaquePointer?
        require(sqlite3_open_v2(defaultHistory.path, &direct, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, "direct open")
        var probe: OpaquePointer?
        let directStatus = sqlite3_prepare_v2(direct, "SELECT count(*) FROM urls", -1, &probe, nil) == SQLITE_OK ? sqlite3_step(probe) : SQLITE_ERROR
        sqlite3_finalize(probe); sqlite3_close(direct)
        require(directStatus != SQLITE_ROW, "fixture lock must make the live file unreadable (got \(directStatus))")
        let whileLocked = ChromeHistoryIndex.read(historyFile: defaultHistory, limit: 100)
        require(whileLocked?.count == 4, "reading goes through a private copy so a locked History still loads: \(String(describing: whileLocked?.count))")
        sqlite3_exec(locked, "ROLLBACK", nil, nil, nil); sqlite3_close(locked)

        // Launcher rows: History prefix, host detail, URL-carrying id, history target.
        let rows = LauncherAction.chromeHistory(entries)
        require(rows[1].name == "History · Issues · Rota" && rows[1].detail == "github.com · Return to open", "row text: \(rows[1])")
        require(rows[1].id == "history:https://github.com/rota/app?tab=issues", "row id carries the URL")
        require(rows[3].name == "History · https://untitled.example.com/page", "untitled pages show their URL")
        guard case .chromeHistory(let url, let title) = rows[1].target else { require(false, "history target"); return }
        require(url == "https://github.com/rota/app?tab=issues" && title == "Issues · Rota", "target payload")
        let byTitle = LauncherAction.search("issues", actions: rows)
        require(byTitle.first?.id == rows[1].id, "title search: \(byTitle.map(\.id))")
        let byHost = LauncherAction.search("docs.example", actions: rows)
        require(byHost.first?.id == rows[0].id, "host search through the id: \(byHost.map(\.id))")

        // The actor never reads while off, serves its cache while fresh, and
        // refreshes on demand once stale.
        let index = ChromeHistoryIndex(profileRoot: root, interval: 3600)
        let disabledSnapshot = await index.snapshot()
        let disabledFlag = await index.isEnabled
        require(disabledSnapshot.isEmpty && disabledFlag == false, "disabled index returns nothing")
        await index.setEnabled(true)
        let first = await index.snapshot()
        require(first.count == 4, "enabled index loads: \(first.count)")
        try makeHistory(at: root.appendingPathComponent("Profile 3"), rows: [
            ("https://new.example.com/", "Brand new", 1, chromeTime(base + 5000), 0)])
        let fresh = await index.snapshot(maxAge: 30)
        require(fresh.count == 4, "a fresh cache is served without touching the files")
        let stale = await index.snapshot(maxAge: 0)
        require(stale.first?.url == "https://new.example.com/", "a stale cache is refreshed")
        async let a = index.refreshNow()
        async let b = index.refreshNow()
        let (ra, rb) = await (a, b)
        require(ra.count == 5 && rb.count == 5, "concurrent refreshes share one read")
        await index.setEnabled(false)
        let cleared = await index.entries
        let afterOff = await index.snapshot()
        require(cleared.isEmpty && afterOff.isEmpty, "turning the feature off drops the cache")

        // 3000 history rows must not slow the per-keystroke search.
        let synthetic = (0..<3000).map { i in
            ChromeHistoryEntry(url: "https://site\(i % 400).example.com/path/\(i)?x=\(i)", title: "Page \(i) about topic \(i % 37)",
                               lastVisit: Date(timeIntervalSince1970: base + Double(i)), visitCount: i % 9)
        }
        let catalog = (0..<120).map { i in
            LauncherAction(id: "app\(i)", name: "App \(i)", detail: "/Applications", target: .registered("app\(i)"))
        } + LauncherAction.chromeHistory(ChromeHistoryIndex.merged([synthetic]))
        require(catalog.count == 3120, "synthetic rows are distinct by site prefix: \(catalog.count)")
        let engine = CommandLine.arguments.dropFirst().first.map { RustApplicationSearch(path: $0) } ?? RustApplicationSearch.shared
        _ = LauncherAction.search("topic", actions: catalog, engine: engine)
        var samples: [Double] = []
        for query in ["t", "to", "top", "topic 3", "site12", "app 7", "page 2999"] {
            let start = DispatchTime.now().uptimeNanoseconds
            let hits = LauncherAction.search(query, actions: catalog, engine: engine)
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
            require(!hits.isEmpty, "query \(query) finds rows")
        }
        samples.sort()
        print(String(format: "launcher search with 3000 history rows (%@): median %.3f ms, max %.3f ms",
                     engine.isAvailable ? "Rust index" : "Swift fallback", samples[samples.count / 2], samples.last!))
        if engine.isAvailable { require(samples[samples.count / 2] < 3, "per-keystroke search stays under 3 ms with the Rust index") }
        print("ChromeHistoryTests passed")
    }
}
