import Foundation
import Combine

@MainActor private final class IntentionClockFixture {
    var instant = ContinuousClock().now
    var wall = Date(timeIntervalSince1970: 10_000)
    var pending: [(ContinuousClock.Instant, CheckedContinuation<Void, Error>)] = []
    func sleep(until deadline: ContinuousClock.Instant) async throws {
        // Deliberately cancellation-unaware to exercise late timer delivery.
        try await withCheckedThrowingContinuation { pending.append((deadline, $0)) }
    }
    func advance(_ seconds: Int) { instant = instant.advanced(by: .seconds(seconds)) }
    func wake(_ index: Int = 0) { pending.remove(at: index).1.resume() }
    func drain() { while !pending.isEmpty { wake() } }
    func store() -> TemporaryIntentionStore {
        TemporaryIntentionStore(now: { self.instant }, wallNow: { self.wall }, sleepUntil: { try await self.sleep(until: $0) })
    }
}

@MainActor private func intentionEventually(_ condition: () -> Bool) async {
    for _ in 0..<2_000 {
        if condition() { return }
        await Task.yield()
    }
    preconditionFailure("Intention fixture did not reach expected state")
}

@main struct TemporaryIntentionTests {
    @MainActor static func main() async throws {
        let clock = IntentionClockFixture(), store = clock.store()
        precondition(store.snapshot() == .empty && store.remainingSeconds == nil)
        precondition(TemporaryIntentionStore().snapshot().text == nil, "New processes/instances have no saved intention")
        try store.set(text: " \n focus on email \t")
        await intentionEventually { clock.pending.count == 1 }
        let first = store.snapshot()
        precondition(first.text == "focus on email" && first.expiration == clock.instant.advanced(by: .seconds(1800)))
        precondition(first.expiresAt == clock.wall.addingTimeInterval(1800))
        precondition(store.remainingSeconds == 1800 && store.isCurrent(first))
        var publications = 0
        let subscription = store.$context.dropFirst().sink { _ in publications += 1 }
        clock.wall = clock.wall.addingTimeInterval(100_000_000)
        clock.advance(1799)
        precondition(store.isCurrent(first) && store.remainingSeconds == 1,
                     "Wall-clock jumps must not change the thirty-minute lifetime")
        clock.wall = Date(timeIntervalSince1970: -100_000_000)
        clock.advance(1)
        precondition(!store.isCurrent(first) && store.snapshot().text == nil && store.remainingSeconds == nil)
        precondition(store.context == first && publications == 0,
                     "Delayed timers cannot authorize expired snapshots; read validation never publishes")
        clock.wake()
        await intentionEventually { store.context.text == nil && publications == 1 }
        precondition(store.context.revision != first.revision, "Expiry must invalidate captured voice context")
        subscription.cancel()

        // A replaced timer may complete after cancellation; it must not clear
        // the replacement or produce an extra published revision.
        try store.set(text: "old")
        await intentionEventually { clock.pending.count == 1 }
        let old = store.snapshot()
        clock.advance(900)
        try store.set(text: "new")
        await intentionEventually { clock.pending.count == 2 }
        let replacement = store.snapshot()
        precondition(!store.isCurrent(old) && store.isCurrent(replacement))
        clock.advance(900); clock.wake()
        for _ in 0..<20 { await Task.yield() }
        precondition(store.context == replacement && store.remainingSeconds == 900)
        clock.advance(900)
        precondition(!store.isCurrent(replacement) && store.snapshot().text == nil)
        store.refreshExpiry()
        let cleared = store.context
        clock.wake()
        for _ in 0..<20 { await Task.yield() }
        precondition(store.context == cleared, "Late replaced/cleared timers cannot publish again")

        try store.set(text: "before explicit clear")
        await intentionEventually { clock.pending.count == 1 }
        store.clear()
        let explicitClear = store.context
        clock.advance(1800); clock.wake()
        for _ in 0..<20 { await Task.yield() }
        precondition(store.context == explicitClear && store.snapshot().text == nil)

        let boundary = String(repeating: "é", count: 500)
        try store.set(text: boundary)
        await intentionEventually { clock.pending.count == 1 }
        let valid = store.snapshot()
        do { try store.set(text: boundary + "é"); preconditionFailure("Oversized intention accepted") }
        catch TemporaryIntentionError.tooLong {}
        precondition(store.context == valid && clock.pending.count == 1,
                     "Invalid edits must preserve the active hint and its expiry")
        try store.set(text: " \n\t ")
        precondition(store.snapshot().text == nil && !store.isCurrent(valid), "Whitespace input clears after trimming")
        clock.drain()
        for _ in 0..<20 { await Task.yield() }
        precondition(TemporaryIntentionStore().snapshot() == .empty)
        print("Temporary intention: memory-only, trim/limit, exact ContinuousClock expiry, delayed validation, wall-clock separation, replacement/clear races: PASS")
    }
}
