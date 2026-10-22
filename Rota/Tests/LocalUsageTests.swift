import Foundation

@main
struct LocalUsageTests {
    static func main() throws {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ label: String) {
            guard value() else { fatalError(label) }; checks += 1
        }
        let a = UsageApp(id: "example.a", name: "App A"), b = UsageApp(id: "example.b", name: "App B")
        func sample(_ time: Double, idle: Double = 0, app: UsageApp? = nil, uptime: Double? = nil) -> UsageClock.Sample {
            .init(wall: time, uptime: uptime ?? time, idle: idle, app: app ?? a, host: nil)
        }
        var clock = UsageClock()
        check(clock.sample(sample(1000)).interval == nil, "No startup backfill")
        let switchUpdate = clock.sample(sample(1005, app: b))
        check(switchUpdate.interval?.app == a, "Activation closes previous app")
        check(clock.sample(sample(1010)).interval?.app == b, "One active app owns time")
        check(clock.sample(sample(1100)).interval == nil, "Missing samples are not filled")
        check(clock.sample(sample(1105, uptime: 1106)).interval != nil, "Small clock drift allowed")
        check(clock.sample(sample(2000, uptime: 1111)).interval == nil, "Wall-clock jump excluded")
        clock.reset()
        check(clock.sample(sample(3000)).interval == nil, "Wake resets accounting")
        let idle = clock.sample(sample(3900, idle: 900))
        check(idle.trimAfter == 3000, "Long idle removes the entire grace interval")
        check(idle.interval == nil, "Idle sample gets no time")
        check(clock.sample(sample(3905, idle: 905)).trimAfter == nil, "Idle trim only once")
        check(clock.sample(sample(3910)).interval == nil, "Resume never catches up idle time")
        check(clock.sample(sample(3915)).interval?.end == 3915, "Input resumes normal accounting")
        clock.reset()
        check(clock.sample(sample(5000, idle: 2000)).trimAfter == 5000, "Startup idle cannot erase old sessions")
        check(UsagePrivacy.host("https://user:password@www.Example.com/private?q=secret#secret") == "example.com", "Only domain retained")
        check(UsagePrivacy.host("file:///private/secret") == nil, "Local URLs excluded")
        check(UsagePrivacy.host("chrome://history") == nil, "Internal browser pages excluded")
        check(UsagePrivacy.host("not a URL") == nil, "Malformed browser values excluded")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rota-usage-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("activity/usage.sqlite")
        let db = try UsageDatabase(url: url)
        try db.append(.init(start: 1000, end: 1010, app: a, host: nil))
        try db.append(.init(start: 1010, end: 1020, app: a, host: nil))
        let merged = try db.intervals(from: 0, to: 5000)
        check(merged.count == 1, "Adjacent same-app samples merge")
        try db.append(.init(start: 1020, end: 1030, app: b, host: "example.com"))
        try db.append(.init(start: 1030, end: 1040, app: b, host: "second.example"))
        let intervals = try db.intervals(from: 1005, to: 1035)
        let report = UsageDatabase.report(intervals)
        check(report.total == 30, "Report clips to requested range")
        check(report.switches == 1, "Domain changes are not app switches")
        check(report.apps.first { $0.id == b.id }?.domains.count == 2, "Domains nested beneath app")
        check(report.apps.first { $0.id == b.id }?.seconds == 15, "Website time not double counted")
        let model = UsageDatabase.prediction(intervals, now: 1040)
        check(model.score(b.id, after: a.id) > model.score(a.id, after: a.id), "Conditional app-switch prediction")
        let candidate: (String?, Int) -> UsagePrediction.Candidate = { .init(appID: $0, textBucket: $1) }
        check(model.order([candidate(a.id, 0), candidate(b.id, 1)], after: a.id) == [0, 1], "History cannot displace exact match")
        check(model.order([candidate(a.id, 1), candidate(b.id, 1)], after: a.id) == [1, 0], "History breaks near-match ties")
        check(model.order([candidate(a.id, 1), candidate(nil, 1), candidate(b.id, 1)], after: a.id) == [0, 1, 2], "Non-app positions remain unchanged")
        check(UsagePrediction().order([candidate(a.id, 1), candidate(b.id, 1)], after: nil) == [0, 1], "No-history order is stable")
        try db.append(.init(start: 1010, end: 1025, app: a, host: nil))
        let rollbackReport = UsageDatabase.report(try db.intervals(from: 0, to: 5000))
        check(rollbackReport.total == 40, "Clock rollback cannot duplicate stored time")
        try db.trim(after: 1015)
        let trimmed = try db.intervals(from: 0, to: 5000)
        check(trimmed.count == 1 && trimmed[0].end == 1015, "Idle trim clips old segments and deletes later segments")
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        check(permissions == 0o600, "Database private permissions")
        try db.recordAction(id: "action_test", name: "Example command", category: "action", at: 1010)
        try db.recordAction(id: "action_test", name: "Example command", category: "action", at: 1020)
        try db.recordAction(id: "key_test", name: "Option+Space", category: "hotkey", at: 1025)
        let actions = try db.actions(from: 1000, to: 1021, category: "action")
        let keys = try db.actions(from: 1000, to: 1030, category: "hotkey")
        check(actions.count == 1 && actions[0].count == 2, "Daily action invocation counts")
        check(actions[0].lastUsed == Date(timeIntervalSince1970: 1020), "Most recent invocation retained")
        check(keys.count == 1 && keys[0].name == "Option+Space", "Hotkey triggers counted separately")
        let catalogue = [UsageActionTotal(id: "action_test", name: "Duplicate", count: 0, lastUsed: nil), UsageActionTotal(id: "unused", name: "Unused action", count: 0, lastUsed: nil)]
        let complete = UsageDatabase.includingUnused(actions, catalogue: catalogue)
        check(complete.count == 2 && complete[1].count == 0, "Configured unused actions visible without duplicating used ones")
        try db.clear()
        let empty = try db.intervals(from: 0, to: 5000)
        check(empty.isEmpty, "Clear removes history")
        let emptyActions = try db.actions(from: 0, to: 5000, category: "action")
        let emptyKeys = try db.actions(from: 0, to: 5000, category: "hotkey")
        check(emptyActions.isEmpty && emptyKeys.isEmpty, "Clear removes action and hotkey history too")
        let link = directory.appendingPathComponent("link.sqlite")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        do { _ = try UsageDatabase(url: link); fatalError("Symlink accepted") }
        catch { checks += 1 }
        let invalid = directory.appendingPathComponent("invalid.sqlite")
        try Data("not a database".utf8).write(to: invalid)
        do { _ = try UsageDatabase(url: invalid); fatalError("Corruption accepted") }
        catch { checks += 1 }
        let preserved = try Data(contentsOf: invalid)
        check(preserved == Data("not a database".utf8), "Corrupt data never replaced")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let spring = calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 12))!
        let day = calendar.dateInterval(of: .day, for: spring)!
        check(day.duration == 23 * 3600, "Day boundaries respect DST")
        print("Local usage: \(checks) checks passed (synthetic data only)")
    }
}
