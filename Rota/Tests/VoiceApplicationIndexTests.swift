import AppKit
import SwiftUI

private final class ScanFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    let gate = DispatchSemaphore(value: 0)
    let blockSecond: Bool
    init(blockSecond: Bool = false) { self.blockSecond = blockSecond }
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
    func scan() -> ExplorerApplicationCatalog.ScanResult {
        dispatchPrecondition(condition: .notOnQueue(.main))
        lock.lock(); count += 1; let current = count; lock.unlock()
        if blockSecond && current == 2 { gate.wait() }
        Thread.sleep(forTimeInterval: 0.05)
        if current == 3 { return .init(applications: [], errors: ["Fixture read failure"]) }
        if current == 5 { return .init(applications: [], errors: []) }
        return .init(applications: (0..<current).map {
            ExplorerApplication(bundleID: "test.app.\($0)", name: "App \($0)", url: URL(fileURLWithPath: "/Applications/App\($0).app"))
        }, errors: [])
    }
}

@MainActor private final class IndexEventFixture: ApplicationIndexChangeObserving {
    private var callback: (@Sendable () -> Void)?
    private var retired: [@Sendable () -> Void] = []
    private var failure: (@Sendable (String) -> Void)?
    private var retiredFailures: [@Sendable (String) -> Void] = []
    var starts = 0, stops = 0
    func start(onChange: @escaping @Sendable () -> Void, onError: @escaping @Sendable (String) -> Void) {
        starts += 1; callback = onChange; failure = onError
    }
    func stop() {
        stops += 1
        if let callback { retired.append(callback) }
        if let failure { retiredFailures.append(failure) }
        callback = nil; failure = nil
    }
    func emit() { callback?() }
    func emitRetired() { retired.forEach { $0() } }
    func fail(_ message: String) { failure?(message) }
    func failRetired() { retiredFailures.forEach { $0("Obsolete watcher failure") } }
}

private final class GatedIndexScanner: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var count = 0, active = 0, maximum = 0
    private var results: [ExplorerApplicationCatalog.ScanResult] = []
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
    var maxActive: Int { lock.lock(); defer { lock.unlock() }; return maximum }
    func scan() -> ExplorerApplicationCatalog.ScanResult {
        dispatchPrecondition(condition: .notOnQueue(.main))
        lock.lock(); count += 1; active += 1; maximum = max(maximum, active); lock.unlock()
        gate.wait() // Intentionally ignores task cancellation until physical drain.
        lock.lock(); let result = results.removeFirst(); active -= 1; lock.unlock()
        return result
    }
    func complete(_ names: [String], error: String? = nil) {
        let result = ExplorerApplicationCatalog.ScanResult(applications: names.map {
            ExplorerApplication(bundleID: "fixture.\($0)", name: $0, url: URL(fileURLWithPath: "/fixture/\($0).app"))
        }, errors: error.map { [$0] } ?? [])
        lock.lock(); results.append(result); lock.unlock(); gate.signal()
    }
}

@MainActor private func indexEventually(_ condition: () -> Bool, _ message: String) async {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while ContinuousClock.now < deadline {
        if condition() { return }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    preconditionFailure(message)
}

@main struct VoiceApplicationIndexTests {
    @MainActor static func main() async {
        let fixture = ScanFixture()
        let index = VoiceApplicationIndex(refreshInterval: 60, scan: { fixture.scan() })
        async let first: Void = index.load()
        async let second: Void = index.refresh(force: true)
        _ = await (first, second)
        precondition(fixture.calls == 1 && index.applications.count == 1, "Concurrent requests must share one scan")
        precondition(index.lastRefreshedAt != nil && !index.isRefreshing && index.refreshError == nil)
        await index.load()
        precondition(fixture.calls == 1, "Fresh cache must avoid disk traversal")
        await index.refresh(force: true)
        precondition(fixture.calls == 2 && index.applications.count == 2, "Force refresh must discover new apps")
        let previousSuccess = index.lastRefreshedAt
        await index.refresh(force: true)
        precondition(index.refreshError == "Fixture read failure" && index.applications.count == 2)
        precondition(index.lastRefreshedAt == previousSuccess && !index.isRefreshing, "Failed refresh retains last successful catalog")
        await index.load()
        precondition(fixture.calls == 3, "Failed attempts are throttled too")
        await index.refresh(force: true)
        precondition(index.applications.count == 4 && index.refreshError == nil)
        await index.refresh(force: true)
        precondition(index.applications.isEmpty && index.refreshError == nil, "Clean scans remove uninstalled applications")
        let expiring = VoiceApplicationIndex(refreshInterval: 0, scan: { fixture.scan() })
        await expiring.load()
        await expiring.load()
        await expiring.refresh(force: true)
        precondition(fixture.calls == 7, "Expired cache is refreshed on next use")
        let blockedFixture = ScanFixture(blockSecond: true)
        let cached = VoiceApplicationIndex(refreshInterval: 0, scan: { blockedFixture.scan() })
        await cached.load()
        await cached.load()
        while blockedFixture.calls < 2 { await Task.yield() }
        // This must return even though the background scanner cannot finish yet.
        await cached.load()
        precondition(cached.applications.count == 1 && cached.isRefreshing && blockedFixture.calls == 2)
        blockedFixture.gate.signal()
        await cached.refresh(force: true)
        precondition(cached.applications.count == 2 && !cached.isRefreshing && blockedFixture.calls == 2,
                     "Stale cached loads return immediately and coalesce background refresh")
        let cancellationFixture = ScanFixture()
        let cancellable = VoiceApplicationIndex(scan: { cancellationFixture.scan() })
        let request = Task { await cancellable.load() }
        await Task.yield()
        request.cancel()
        await request.value
        await cancellable.load()
        precondition(cancellationFixture.calls == 1 && cancellable.applications.count == 1 && !cancellable.isRefreshing,
                     "Cancelled callers must not cancel the shared scan or leave it stuck")
        let deferredFixture = ScanFixture()
        let deferred = VoiceApplicationIndex(refreshInterval: 0, scan: { deferredFixture.scan() })
        await deferred.load()
        await deferred.load()
        deferred.stop()
        for _ in 0..<30 { await Task.yield() }
        precondition(deferredFixture.calls == 1 && deferred.applications.count == 1,
            "A deferred TTL cache refresh must not dispatch after synchronous stop")
        let events = IndexEventFixture(), scanner = GatedIndexScanner()
        let automatic = VoiceApplicationIndex(refreshInterval: 60, debounceInterval: 0,
            observation: events, scan: { scanner.scan() })
        automatic.start(); automatic.start()
        precondition(events.starts == 1, "Automatic startup must be idempotent")
        await indexEventually({ scanner.calls == 1 }, "Startup must dispatch a physical background scan")
        var heartbeat = false
        Task { @MainActor in heartbeat = true }
        await indexEventually({ heartbeat }, "MainActor must remain responsive while the scanner is suspended")
        for _ in 0..<100 { events.emit() }
        for _ in 0..<30 { await Task.yield() }
        precondition(scanner.calls == 1 && scanner.maxActive == 1, "Event bursts cannot start overlapping physical scans")
        scanner.complete(["First"])
        await indexEventually({ scanner.calls == 2 }, "Changes during a scan must request one follow-up traversal")
        events.fail("Synthetic watcher unavailable")
        await indexEventually({ automatic.observationError == "Synthetic watcher unavailable" }, "Watcher setup failures must be visible separately from scan failures")
        scanner.complete(["Second"])
        await indexEventually({ !automatic.isRefreshing && automatic.applications.map(\.name) == ["Second"] }, "Follow-up result must publish")
        precondition(scanner.calls == 2 && scanner.maxActive == 1, "A hundred events must coalesce into only one pending scan")
        precondition(automatic.observationError == "Synthetic watcher unavailable" && automatic.refreshError == nil,
            "A successful scan must not imply that failed automatic observation recovered")
        await automatic.load()
        precondition(scanner.calls == 2, "Voice/cache reads must reuse the complete automatic snapshot")
        let failedRefresh = Task { await automatic.refresh(force: true) }
        await indexEventually({ scanner.calls == 3 }, "Manual force must bypass the fresh cache")
        scanner.complete([], error: "Synthetic observation failure")
        await failedRefresh.value
        precondition(automatic.applications.map(\.name) == ["Second"] && automatic.refreshError == "Synthetic observation failure")
        precondition(automatic.observationError == "Synthetic watcher unavailable", "Scan and watcher failures must retain independent status")
        let successAt = automatic.lastRefreshedAt
        events.emit()
        await indexEventually({ scanner.calls == 4 }, "Observation should recover after a failed manual scan")
        automatic.stop(); automatic.start()
        events.emitRetired(); events.failRetired()
        precondition(events.starts == 2 && scanner.calls == 4, "Restart cannot overlap a physically suspended stopped generation")
        scanner.complete(["Obsolete"])
        await indexEventually({ scanner.calls == 5 }, "Restart must scan once the old physical operation drains")
        precondition(automatic.applications.map(\.name) == ["Second"] && automatic.lastRefreshedAt == successAt,
            "A stopped generation's late success must not replace the cached catalog")
        scanner.complete(["Restarted"])
        await indexEventually({ !automatic.isRefreshing && automatic.applications.map(\.name) == ["Restarted"] }, "Current restart must publish")
        precondition(automatic.observationError == nil, "Explicit restart retries observation and rejects stale watcher errors")
        let beforeStop = automatic.lastRefreshedAt
        events.emit(); await indexEventually({ scanner.calls == 6 }, "Final stop fixture must suspend")
        automatic.stop(); scanner.complete([], error: "Obsolete error")
        for _ in 0..<30 { await Task.yield() }
        events.emitRetired(); events.failRetired()
        for _ in 0..<30 { await Task.yield() }
        precondition(scanner.calls == 6 && scanner.maxActive == 1 && automatic.applications.map(\.name) == ["Restarted"] &&
            automatic.lastRefreshedAt == beforeStop && automatic.refreshError == nil && automatic.observationError == nil,
            "Stop must reject late errors and retired callbacks without losing the last complete snapshot")
        print("Application index passed: background scans, coalescing, TTL, force refresh, removals, error retention, recovery, and caller cancellation.")
    }
}
