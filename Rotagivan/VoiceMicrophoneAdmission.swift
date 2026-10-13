import Foundation

/// Note entry is a process-wide separation boundary, not just a microphone
/// toggle. Action voice may not record while any note editor is visible.
@MainActor final class VoiceMicrophoneAdmission {
    static let shared = VoiceMicrophoneAdmission()
    private enum Owner {
        case cloud(UUID, () -> Void)
        case privateCapture(UUID)
        var id: UUID {
            switch self { case .cloud(let id, _), .privateCapture(let id): return id }
        }
    }
    private var owner: Owner?
    private var privateEntries = Set<UUID>()
    private var cloudSessions: [UUID: () -> Void] = [:]
    var occupied: Bool { owner != nil }
    var privateEntryActive: Bool { !privateEntries.isEmpty }
    func beginPrivateEntry(_ id: UUID) {
        privateEntries.insert(id)
        cancelCloud()
    }
    func endPrivateEntry(_ id: UUID) { privateEntries.remove(id) }
    func acquireCloud(_ id: UUID, cancel: @escaping () -> Void) -> Bool {
        guard privateEntries.isEmpty, owner == nil else { return false }
        owner = .cloud(id, cancel)
        cloudSessions[id] = cancel
        return true
    }
    func registerCloud(_ id: UUID, cancel: @escaping () -> Void) -> Bool {
        guard privateEntries.isEmpty else { return false }
        if case .privateCapture = owner { return false }
        cloudSessions[id] = cancel
        return true
    }
    func acquirePrivate(_ id: UUID) -> Bool {
        cancelCloud()
        guard owner == nil else { return false }
        owner = .privateCapture(id)
        return true
    }
    func release(_ id: UUID) { if owner?.id == id { owner = nil } }
    /// Matching/ready sessions remain cancellable after their mic is stopped.
    func endCloud(_ id: UUID) { cloudSessions[id] = nil }
    func cancelCloud() {
        for cancel in Array(cloudSessions.values) { cancel() }
    }
}
