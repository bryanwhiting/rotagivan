import Foundation
import Combine

/// Immutable local note snapshot; never used in action matching or synced.
struct TemporaryNoteSnapshot: Equatable, Sendable {
    let revision: UUID
    let text: String?
    let expiration: ContinuousClock.Instant?
    /// Wall-clock presentation only; never used to authorize a request/action.
    let expiresAt: Date?

    static let empty = TemporaryNoteSnapshot(revision: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
        text: nil, expiration: nil, expiresAt: nil)
}

enum TemporaryIntentionError: LocalizedError {
    case tooLong
    var errorDescription: String? { "Keep the temporary intention to 500 characters or fewer." }
}

/// A local, process-lifetime note. ContinuousClock advances across system sleep;
/// Date is used only for the expiration label, not the thirty-minute lifetime.
@MainActor final class TemporaryIntentionStore: ObservableObject {
    static let shared = TemporaryIntentionStore()
    static let maximumCharacters = 500
    static let lifetime: Duration = .seconds(30 * 60)
    @Published private(set) var context = TemporaryNoteSnapshot.empty
    private var expiryTask: Task<Void, Never>?
    private let now: () -> ContinuousClock.Instant
    private let wallNow: () -> Date
    private let sleepUntil: @MainActor (ContinuousClock.Instant) async throws -> Void

    init(now: @escaping () -> ContinuousClock.Instant = { ContinuousClock().now },
         wallNow: @escaping () -> Date = { Date() },
         sleepUntil: @escaping @MainActor (ContinuousClock.Instant) async throws -> Void = {
             try await ContinuousClock().sleep(until: $0)
         }) {
        self.now = now; self.wallNow = wallNow; self.sleepUntil = sleepUntil
    }

    /// Safe during view evaluation: expiry is projected without publishing.
    /// Request/confirmation validation does not depend on timely timer delivery.
    func snapshot() -> TemporaryNoteSnapshot {
        guard let deadline = context.expiration, now() >= deadline else { return context }
        return TemporaryNoteSnapshot(revision: context.revision, text: nil, expiration: nil, expiresAt: nil)
    }

    func isCurrent(_ captured: TemporaryNoteSnapshot) -> Bool {
        captured == snapshot()
    }

    var remainingSeconds: Int? {
        guard let deadline = snapshot().expiration else { return nil }
        let duration = now().duration(to: deadline).components
        return max(0, Int(ceil(Double(duration.seconds) + Double(duration.attoseconds) / 1e18)))
    }

    /// Explicit wake/lifecycle hook, never called from View.body. A delayed
    /// sleeper does not keep expired text active or require periodic polling.
    func refreshExpiry() {
        if let deadline = context.expiration, now() >= deadline { clear() }
    }

    func set(text: String) throws {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count <= Self.maximumCharacters else { throw TemporaryIntentionError.tooLong }
        guard !value.isEmpty else { clear(); return }
        expiryTask?.cancel()
        let revision = UUID(), deadline = now().advanced(by: Self.lifetime)
        context = TemporaryNoteSnapshot(revision: revision, text: value, expiration: deadline,
            expiresAt: wallNow().addingTimeInterval(30 * 60))
        let sleepUntil = sleepUntil
        expiryTask = Task { @MainActor [weak self] in
            do { try await sleepUntil(deadline) } catch { return }
            guard !Task.isCancelled, let self, self.context.revision == revision,
                  self.now() >= deadline else { return }
            self.clear()
        }
    }

    func clear() {
        expiryTask?.cancel(); expiryTask = nil
        context = TemporaryNoteSnapshot(revision: UUID(), text: nil, expiration: nil, expiresAt: nil)
    }

    deinit { expiryTask?.cancel() }
}
