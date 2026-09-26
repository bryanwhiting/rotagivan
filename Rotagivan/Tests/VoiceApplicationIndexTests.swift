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
        print("Application index passed: background scans, coalescing, TTL, force refresh, removals, error retention, recovery, and caller cancellation.")
    }
}
