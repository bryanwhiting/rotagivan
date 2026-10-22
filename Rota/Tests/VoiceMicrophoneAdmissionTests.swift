import Foundation

@main struct VoiceMicrophoneAdmissionTests {
    @MainActor static func main() {
        let gate = VoiceMicrophoneAdmission(), cloud = UUID(), first = UUID(), second = UUID(), local = UUID()
        var cancellations = 0
        precondition(gate.acquireCloud(cloud, cancel: { cancellations += 1 }))
        gate.beginPrivateEntry(first)
        precondition(cancellations == 1 && gate.occupied && gate.privateEntryActive)
        precondition(!gate.acquirePrivate(local), "Cancellation is not permission/microphone drain")
        gate.release(cloud); gate.endCloud(cloud)
        precondition(gate.acquirePrivate(local))
        gate.beginPrivateEntry(second); gate.endPrivateEntry(first)
        precondition(gate.privateEntryActive && !gate.acquireCloud(UUID(), cancel: {}))
        gate.endPrivateEntry(second)
        precondition(!gate.privateEntryActive && !gate.acquireCloud(UUID(), cancel: {}),
            "Closing all editors cannot free a private capture which is still draining")
        gate.release(UUID())
        precondition(gate.occupied, "Wrong-owner release must not clear a lease")
        gate.release(local)
        let ready = UUID()
        precondition(gate.registerCloud(ready, cancel: { cancellations += 1; gate.endCloud(ready) }))
        gate.beginPrivateEntry(first)
        precondition(cancellations >= 2 && !gate.acquireCloud(UUID(), cancel: {}),
            "Private entry also cancels ready/matching sessions whose mic already stopped")
        gate.endPrivateEntry(first)
        precondition(gate.acquireCloud(UUID(), cancel: {}))
        print("Microphone admission passed private editor ownership, cancellation/drain, ready-session revocation and no overlapping capture.")
    }
}
