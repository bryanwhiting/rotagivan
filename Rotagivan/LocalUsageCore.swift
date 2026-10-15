import Foundation
import SQLite3
import Darwin

struct UsageApp: Equatable, Sendable {
    let id: String
    let name: String
}
struct UsageInterval: Equatable, Sendable {
    let start: TimeInterval
    let end: TimeInterval
    let app: UsageApp
    let host: String?
}

/// A single frontmost app owns each interval. Missing samples, sleep, and clock
/// changes are not filled in. Long idle periods are removed back to last input.
struct UsageClock {
    struct Sample {
        let wall: TimeInterval
        let uptime: TimeInterval
        let idle: TimeInterval
        let app: UsageApp?
        let host: String?
    }
    struct Update {
        var interval: UsageInterval?
        var trimAfter: TimeInterval?
    }
    private var previous: Sample?
    private var runStart: TimeInterval?
    private var wasIdle = false
    mutating func reset() { previous = nil; runStart = nil; wasIdle = false }
    mutating func sample(_ next: Sample) -> Update {
        var result = Update()
        if runStart == nil { runStart = next.wall }
        let idle = !next.idle.isFinite || next.idle < 0 || next.idle >= 900
        if idle && !wasIdle && next.idle.isFinite && next.idle >= 900 {
            result.trimAfter = max(runStart ?? next.wall, next.wall - next.idle)
        }
        if let old = previous {
            let elapsed = next.uptime - old.uptime
            let wallElapsed = next.wall - old.wall
            if !idle, !wasIdle, elapsed > 0, elapsed <= 30,
               abs(elapsed - wallElapsed) < 2, let app = old.app {
                result.interval = UsageInterval(start: old.wall, end: next.wall, app: app, host: old.host)
            }
        }
        wasIdle = idle
        previous = next
        return result
    }
}

enum UsagePrivacy {
    /// Deliberately discard scheme, credentials, path, query, fragment and title.
    static func host(_ value: String) -> String? {
        guard let url = URLComponents(string: value),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host?.lowercased(), !host.isEmpty, host.count <= 253 else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

struct UsageDomainTotal: Identifiable, Sendable {
    var id: String { host }
    let host: String
    let seconds: Double
}
struct UsageAppTotal: Identifiable, Sendable {
    let id: String
    let name: String
    let seconds: Double
    let domains: [UsageDomainTotal]
}
struct UsageReport: Sendable {
    var apps: [UsageAppTotal] = []
    var switches = 0
    var total: Double { apps.reduce(0) { $0 + $1.seconds } }
}
struct UsageActionTotal: Identifiable, Sendable {
    let id: String
    let name: String
    let count: Int
    let lastUsed: Date?
}
struct UsagePrediction: Sendable {
    struct Candidate {
        let appID: String?
        let textBucket: Int // 0 exact, 1 prefix, 2 substring, 3 fuzzy
    }
    var frequency: [String: Double] = [:]
    var transitions: [String: [String: Double]] = [:]
    func score(_ id: String, after current: String?) -> Double {
        let global = frequency[id, default: 0] / max(1, frequency.values.reduce(0, +))
        let row = current.flatMap { transitions[$0] } ?? [:]
        // Additive smoothing keeps a few switches from overwhelming text search.
        let conditional = (row[id, default: 0] + global * 3) / (row.values.reduce(0, +) + 3)
        return 0.4 * global + 0.6 * conditional
    }
    /// Preserve non-app positions and exact matches; the prior is only a bounded
    /// tie-breaker within at most four equally text-relevant app candidates.
    func order(_ candidates: [Candidate], after current: String?) -> [Int] {
        var indices = Array(candidates.indices), start = 0
        while start < indices.count {
            guard candidates[start].appID != nil else { start += 1; continue }
            let group = candidates[start].textBucket
            var end = start + 1
            while end < min(start + 4, candidates.count), candidates[end].appID != nil,
                  candidates[end].textBucket == group { end += 1 }
            if group != 0 {
                let ordered = indices[start..<end].sorted { left, right in
                    let a = score(candidates[left].appID!, after: current)
                    let b = score(candidates[right].appID!, after: current)
                    return a == b ? left < right : a > b
                }
                indices.replaceSubrange(start..<end, with: ordered)
            }
            start = end
        }
        return indices
    }
}

/// This database is intentionally unrelated to StoredSettings, cloud sync, voice
/// prompts, and configuration exports. Caller serializes access off the UI thread.
final class UsageDatabase {
    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    enum Failure: Error, LocalizedError {
        case storage(String)
        var errorDescription: String? { "Local activity storage: " + message }
        private var message: String { if case .storage(let s) = self { return s }; return "Unavailable" }
    }
    init(url: URL) throws {
        let fm = FileManager.default, directory = url.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let directoryInfo = try fm.attributesOfItem(atPath: directory.path)
        guard directoryInfo[.type] as? FileAttributeType == .typeDirectory else { throw Failure.storage("Not a private directory.") }
        if fm.fileExists(atPath: url.path) {
            guard try fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeRegular else {
                throw Failure.storage("Refusing a non-regular database file.")
            }
        }
        // NOFOLLOW rejects a substituted database symlink as well as the check above.
        // Resolve the parent (e.g. macOS /var -> /private/var) without resolving
        // the database leaf: NOFOLLOW still protects against a substituted file.
        guard let resolved = realpath(directory.path, nil) else { throw Failure.storage("Could not resolve storage directory.") }
        let path = URL(fileURLWithPath: String(cString: resolved)).appendingPathComponent(url.lastPathComponent).path
        free(resolved)
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }; db = nil
            throw Failure.storage("Could not open database.")
        }
        do {
            let marker = try scalar("PRAGMA application_id")
            let tables = try scalar("SELECT count(*) FROM sqlite_master WHERE type='table'")
            guard marker == 0x52555347 || (marker == 0 && tables == 0) else { throw Failure.storage("Unrecognized database; not modified.") }
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            var excluded = URLResourceValues(); excluded.isExcludedFromBackup = true
            var folder = directory; try folder.setResourceValues(excluded)
            try execute("PRAGMA application_id=0x52555347; PRAGMA journal_mode=DELETE; PRAGMA temp_store=MEMORY; PRAGMA secure_delete=ON; CREATE TABLE IF NOT EXISTS segments (id INTEGER PRIMARY KEY, start REAL NOT NULL, end REAL NOT NULL, app TEXT NOT NULL, name TEXT NOT NULL, host TEXT NOT NULL); CREATE INDEX IF NOT EXISTS segment_time ON segments(end);")
            try execute("CREATE TABLE IF NOT EXISTS invocations(time REAL NOT NULL, action TEXT NOT NULL, name TEXT NOT NULL, category TEXT NOT NULL); CREATE INDEX IF NOT EXISTS invocation_time ON invocations(time);")
        } catch { sqlite3_close(db); db = nil; throw error }
    }
    deinit { if let db { sqlite3_close(db) } }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw Failure.storage("A database operation failed. History was not replaced.") }
    }
    private func statement(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw Failure.storage("Could not read activity data.") }
        return stmt
    }
    private func scalar(_ sql: String) throws -> Int {
        let s = try statement(sql); defer { sqlite3_finalize(s) }
        guard sqlite3_step(s) == SQLITE_ROW else { throw Failure.storage("Could not identify database.") }
        return Int(sqlite3_column_int(s, 0))
    }
    private func string(_ s: OpaquePointer, _ col: Int32) -> String {
        sqlite3_column_text(s, col).map { String(cString: $0) } ?? ""
    }
    func append(_ interval: UsageInterval) throws {
        guard interval.start.isFinite, interval.end.isFinite, interval.end > interval.start,
              interval.end - interval.start <= 30 else { return }
        let last = try statement("SELECT id,end,app,host FROM segments ORDER BY id DESC LIMIT 1")
        var mergeID: Int64?, overlap = false
        if sqlite3_step(last) == SQLITE_ROW {
            let end = sqlite3_column_double(last, 1)
            overlap = interval.start < end - 0.01
            if abs(end - interval.start) < 0.01,
               string(last, 2) == interval.app.id, string(last, 3) == (interval.host ?? "") {
                mergeID = sqlite3_column_int64(last, 0)
            }
        }
        sqlite3_finalize(last)
        // A backward wall-clock adjustment must not count an old period twice.
        guard !overlap else { return }
        let s = try statement(mergeID == nil ? "INSERT INTO segments(start,end,app,name,host) VALUES(?,?,?,?,?)" : "UPDATE segments SET end=? WHERE id=?")
        defer { sqlite3_finalize(s) }
        if let id = mergeID {
            sqlite3_bind_double(s, 1, interval.end); sqlite3_bind_int64(s, 2, id)
        } else {
            sqlite3_bind_double(s, 1, interval.start); sqlite3_bind_double(s, 2, interval.end)
            sqlite3_bind_text(s, 3, String(interval.app.id.prefix(255)), -1, transient)
            sqlite3_bind_text(s, 4, String(interval.app.name.prefix(256)), -1, transient)
            sqlite3_bind_text(s, 5, interval.host ?? "", -1, transient)
        }
        guard sqlite3_step(s) == SQLITE_DONE else { throw Failure.storage("Could not save activity.") }
    }
    func trim(after boundary: Double) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            for sql in ["DELETE FROM segments WHERE start>=?", "UPDATE segments SET end=? WHERE end>?"] {
                let s = try statement(sql); defer { sqlite3_finalize(s) }
                sqlite3_bind_double(s, 1, boundary)
                if sqlite3_bind_parameter_count(s) == 2 { sqlite3_bind_double(s, 2, boundary) }
                guard sqlite3_step(s) == SQLITE_DONE else { throw Failure.storage("Could not remove idle time.") }
            }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
    func intervals(from start: Double, to end: Double) throws -> [UsageInterval] {
        let s = try statement("SELECT start,end,app,name,host FROM segments WHERE end>? AND start<? ORDER BY start,id")
        defer { sqlite3_finalize(s) }
        sqlite3_bind_double(s, 1, start); sqlite3_bind_double(s, 2, end)
        var result: [UsageInterval] = []
        while true {
            let code = sqlite3_step(s)
            if code == SQLITE_DONE { return result }
            guard code == SQLITE_ROW else { throw Failure.storage("Could not read activity history.") }
            let host = string(s, 4)
            result.append(UsageInterval(start: max(start, sqlite3_column_double(s, 0)), end: min(end, sqlite3_column_double(s, 1)),
                app: UsageApp(id: string(s, 2), name: string(s, 3)), host: host.isEmpty ? nil : host))
        }
    }
    func recordAction(id: String, name: String, category: String, at time: Double) throws {
        guard time.isFinite, ["action", "hotkey"].contains(category), !id.isEmpty else { return }
        let s = try statement("INSERT INTO invocations(time,action,name,category) VALUES(?,?,?,?)")
        defer { sqlite3_finalize(s) }
        sqlite3_bind_double(s, 1, time)
        sqlite3_bind_text(s, 2, String(id.prefix(256)), -1, transient)
        sqlite3_bind_text(s, 3, String(name.prefix(256)), -1, transient)
        sqlite3_bind_text(s, 4, category, -1, transient)
        guard sqlite3_step(s) == SQLITE_DONE else { throw Failure.storage("Could not save action usage.") }
    }
    func actions(from start: Double, to end: Double, category: String) throws -> [UsageActionTotal] {
        let s = try statement("SELECT action,name,COUNT(*),MAX(time) FROM invocations WHERE time>=? AND time<? AND category=? GROUP BY action ORDER BY COUNT(*) DESC,action")
        defer { sqlite3_finalize(s) }
        sqlite3_bind_double(s, 1, start); sqlite3_bind_double(s, 2, end)
        sqlite3_bind_text(s, 3, category, -1, transient)
        var result: [UsageActionTotal] = []
        while true {
            let code = sqlite3_step(s)
            if code == SQLITE_DONE { return result }
            guard code == SQLITE_ROW else { throw Failure.storage("Could not read action usage.") }
            result.append(.init(id: string(s, 0), name: string(s, 1), count: Int(sqlite3_column_int(s, 2)), lastUsed: Date(timeIntervalSince1970: sqlite3_column_double(s, 3))))
        }
    }
    static func includingUnused(_ used: [UsageActionTotal], catalogue: [UsageActionTotal]) -> [UsageActionTotal] {
        let usedIDs = Set(used.map(\.id))
        var seen = usedIDs
        return used + catalogue.filter { seen.insert($0.id).inserted }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    func clear() throws {
        do { try execute("BEGIN IMMEDIATE; DELETE FROM segments; DELETE FROM invocations; COMMIT; VACUUM;") }
        catch { try? execute("ROLLBACK"); throw error }
    }
    static func report(_ intervals: [UsageInterval]) -> UsageReport {
        var times: [String: Double] = [:], names: [String: String] = [:], domains: [String: [String: Double]] = [:]
        var previous: UsageInterval?, switches = 0
        for item in intervals {
            let duration = max(0, item.end - item.start)
            times[item.app.id, default: 0] += duration; names[item.app.id] = item.app.name
            if let host = item.host { domains[item.app.id, default: [:]][host, default: 0] += duration }
            if let old = previous, old.app.id != item.app.id, item.start - old.end < 30 { switches += 1 }
            previous = item
        }
        return UsageReport(apps: times.map { id, seconds in
            UsageAppTotal(id: id, name: names[id] ?? id, seconds: seconds,
                domains: (domains[id] ?? [:]).map { UsageDomainTotal(host: $0.key, seconds: $0.value) }.sorted { $0.seconds > $1.seconds })
        }.sorted { $0.seconds > $1.seconds }, switches: switches)
    }
    static func prediction(_ intervals: [UsageInterval], now: Double) -> UsagePrediction {
        var result = UsagePrediction(), previous: UsageInterval?
        for item in intervals {
            let weight = pow(0.5, max(0, now - item.end) / (7 * 86400))
            // Duration is capped so an all-day background mistake cannot dominate.
            result.frequency[item.app.id, default: 0] += min(1800, item.end - item.start) * weight
            if let old = previous, old.app.id != item.app.id, item.start - old.end < 30 {
                result.transitions[old.app.id, default: [:]][item.app.id, default: 0] += weight
            }
            previous = item
        }
        return result
    }
}
