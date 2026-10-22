import Foundation

@MainActor private final class NoteMicrophoneFixture: VoiceAudioCapturing {
    let buffer = VoiceAudioBuffer()
    var starts = 0, stops = 0
    func start() throws { starts += 1; buffer.append(Data(repeating: 1, count: 320), rms: 0.1) }
    func stop() { stops += 1 }
}
private final class NoteCloudFixture: VoiceCloudServing {
    var uploads: [Data] = []
    var waiter: CheckedContinuation<String, Error>?
    var closes = 0
    func transcribe(_ wav: Data) async throws -> String {
        uploads.append(wav)
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }
    func classify(_ transcript: String, catalog: [VoiceRegisteredAction]) async throws -> VoiceDecision {
        preconditionFailure("Note dictation must never classify or call Jev")
    }
    func close() { closes += 1 }
    func complete(_ text: String) { let continuation = waiter; waiter = nil; continuation?.resume(returning: text) }
}
@MainActor private final class NoteTimers {
    var waits: [(Duration, CheckedContinuation<Void, Error>)] = []
    func sleep(_ duration: Duration) async throws {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { waits.append((duration, $0)) }
    }
    func drain() { while !waits.isEmpty { waits.removeFirst().1.resume() } }
}
@MainActor private func noteEventually(line: UInt = #line, _ condition: () -> Bool) async {
    for _ in 0..<2_000 { if condition() { return }; await Task.yield() }
    preconditionFailure("Note fixture did not reach expected state at line \(line)")
}
@main struct NoteDictationTests {
    @MainActor static func main() async {
        let mic = NoteMicrophoneFixture(), gate = VoiceMicrophoneAdmission(), pipeline = VoicePipelineAdmission()
        let cloud = NoteCloudFixture(), timers = NoteTimers()
        var allowed = false, permissionWaiter: CheckedContinuation<Bool, Never>?
        var delayed = false
        var clock = ContinuousClock().now
        let service = NoteDictationSession(microphone: mic, admission: gate, pipelineAdmission: pipeline,
            makeCloud: { cloud }, requestPermission: {
                if delayed { return await withCheckedContinuation { permissionWaiter = $0 } }
                return allowed
            }, sleep: { try await timers.sleep($0) }, now: { clock })
        precondition(mic.starts == 0 && cloud.uploads.isEmpty, "Editor construction must do no preparation or upload")
        service.start()
        await noteEventually { service.phase == .failed && !gate.occupied }
        precondition(mic.starts == 0 && cloud.uploads.isEmpty)
        delayed = true; service.start()
        await noteEventually { permissionWaiter != nil }
        service.cancel()
        precondition(gate.occupied && service.transcript.isEmpty)
        permissionWaiter?.resume(returning: true); permissionWaiter = nil
        await noteEventually { !gate.occupied }
        precondition(mic.starts == 0)
        timers.drain(); for _ in 0..<20 { await Task.yield() }

        delayed = false; allowed = true; service.start()
        await noteEventually { service.phase == .listening }
        precondition(cloud.uploads.isEmpty, "There are no partial uploads")
        service.stop()
        await noteEventually { cloud.waiter != nil }
        precondition(!gate.occupied && pipeline.occupied && cloud.uploads.count == 1)
        precondition(String(data: cloud.uploads[0].prefix(4), encoding: .utf8) == "RIFF")
        service.cancel()
        precondition(pipeline.occupied && cloud.closes > 0, "Cancellation retains provider admission until actual drain")
        service.start(); precondition(service.phase == .cancelled)
        cloud.complete("late secret text")
        await noteEventually { !pipeline.occupied }
        precondition(service.transcript.isEmpty && service.phase == .cancelled)
        timers.drain(); for _ in 0..<20 { await Task.yield() }

        service.start(); await noteEventually { service.phase == .listening }
        service.stop(); await noteEventually { cloud.waiter != nil }
        cloud.complete("  editable note  ")
        await noteEventually { service.phase == .finished && !pipeline.occupied }
        precondition(service.transcript == "editable note")
        precondition(TemporaryIntentionStore().snapshot().text == nil, "Transcription does not auto-save a note")
        service.cancel(); precondition(service.transcript.isEmpty)
        timers.drain(); for _ in 0..<20 { await Task.yield() }

        service.start(); await noteEventually { service.phase == .listening }
        service.stop(); await noteEventually { cloud.waiter != nil }
        clock = clock.advanced(by: .seconds(15))
        cloud.complete("deadline text")
        await noteEventually { service.phase == .failed && !pipeline.occupied }
        precondition(service.transcript.isEmpty, "Response-boundary deadline rejects delayed results without timer delivery")
        timers.drain(); for _ in 0..<20 { await Task.yield() }
        // Drop the service in the same actor turn that enqueues transcription,
        // before its weak-self task can enter. The shared lease must still drain.
        let droppedMic = NoteMicrophoneFixture(), droppedCloud = NoteCloudFixture()
        let droppedPipeline = VoicePipelineAdmission(), droppedGate = VoiceMicrophoneAdmission()
        var dropped: NoteDictationSession? = NoteDictationSession(microphone: droppedMic,
            admission: droppedGate, pipelineAdmission: droppedPipeline,
            makeCloud: { droppedCloud }, requestPermission: { true })
        dropped?.start()
        await noteEventually { dropped?.phase == .listening }
        // Preparation's defer must finish before testing the independently
        // queued transcription task's weak lifetime.
        for _ in 0..<20 { await Task.yield() }
        weak var weakDropped = dropped
        dropped?.stop()
        precondition(droppedPipeline.occupied)
        dropped = nil
        precondition(weakDropped == nil, "Queued transcription must not retain the editor service")
        await noteEventually { !droppedPipeline.occupied }
        precondition(droppedCloud.uploads.isEmpty && droppedCloud.closes > 0)
        print("Note dictation: explicit start, permission cancellation, single WAV/STT only, actual drain admission, editable local output, deadline: PASS")
    }
}
