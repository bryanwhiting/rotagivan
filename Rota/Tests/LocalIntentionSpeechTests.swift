import Foundation
import Speech

@MainActor private final class LocalSpeechFixture: LocalIntentionSpeechBackend {
    var supportsOnDeviceRecognition = true
    var permissions = true, delayPermissions = false
    var permissionCalls = 0, starts = 0, stops = 0, cancels = 0
    var permissionWaiters: [CheckedContinuation<Bool, Never>] = []
    var callbacks: [(@MainActor (String, Bool) -> Void, @MainActor () -> Void)] = []
    func requestPermissions() async throws -> Bool {
        permissionCalls += 1
        if delayPermissions { return await withCheckedContinuation { permissionWaiters.append($0) } }
        return permissions
    }
    func start(onTranscript: @escaping @MainActor (String, Bool) -> Void,
               onError: @escaping @MainActor () -> Void) throws {
        precondition(supportsOnDeviceRecognition && permissions)
        starts += 1; callbacks.append((onTranscript, onError))
    }
    func stop() { stops += 1 }
    func cancel() { cancels += 1; stop() }
    func authorize(_ allowed: Bool) { permissionWaiters.removeFirst().resume(returning: allowed) }
}

@MainActor private final class LocalSpeechTimers {
    var pending: [(Duration, CheckedContinuation<Void, Error>)] = []
    func sleep(_ duration: Duration) async throws {
        try Task.checkCancellation()
        // Ignore cancellation until explicitly resumed, exercising late timers.
        try await withCheckedThrowingContinuation { pending.append((duration, $0)) }
    }
    func wakeLast() { pending.removeLast().1.resume() }
    func drain() { while !pending.isEmpty { pending.removeFirst().1.resume() } }
}

@MainActor private func localSpeechEventually(line: UInt = #line, _ condition: () -> Bool) async {
    for _ in 0..<2_000 { if condition() { return }; await Task.yield() }
    preconditionFailure("Private dictation fixture did not reach expected state at line \(line)")
}

@main struct LocalIntentionSpeechTests {
    @MainActor static func main() async {
        let nativeRequest = LocalIntentionSpeechPrivacy.request()
        precondition(nativeRequest.requiresOnDeviceRecognition && nativeRequest.shouldReportPartialResults,
                     "The actual native request must prohibit server fallback and support live editable text")
        let gate = VoiceMicrophoneAdmission(), backend = LocalSpeechFixture(), timers = LocalSpeechTimers()
        let service = LocalIntentionSpeech(backend: backend, admission: gate, sleep: { try await timers.sleep($0) })
        backend.supportsOnDeviceRecognition = false
        service.start()
        precondition(service.phase == .failed && backend.permissionCalls == 0 && backend.starts == 0 && !gate.occupied,
                     "Unsupported local recognition must fail before permissions/audio")
        backend.supportsOnDeviceRecognition = true; backend.permissions = false
        service.start()
        await localSpeechEventually { service.phase == .failed && !gate.occupied }
        precondition(backend.starts == 0, "Denied permissions never capture audio")

        backend.permissions = true; backend.delayPermissions = true
        service.start()
        await localSpeechEventually { backend.permissionWaiters.count == 1 }
        service.cancel()
        precondition(service.transcript.isEmpty)
        let cloud = UUID()
        precondition(!gate.acquireCloud(cloud, cancel: {}), "Canceled permission preparation must retain admission until acknowledgement")
        backend.authorize(true)
        await localSpeechEventually { !gate.occupied }
        precondition(service.phase == .cancelled && backend.starts == 0)
        timers.drain()
        for _ in 0..<20 { await Task.yield() }

        // A permission watchdog updates UI immediately without pretending that
        // an unacknowledged permission operation or microphone lease is gone.
        service.start()
        await localSpeechEventually { backend.permissionWaiters.count == 1 && !timers.pending.isEmpty }
        precondition(timers.pending.last?.0 == .seconds(30))
        timers.wakeLast()
        await localSpeechEventually { service.phase == .failed }
        precondition(gate.occupied && backend.starts == 0)
        backend.authorize(true)
        await localSpeechEventually { !gate.occupied }

        backend.delayPermissions = false
        service.start()
        await localSpeechEventually { service.phase == .listening && backend.callbacks.count == 1 && !timers.pending.isEmpty }
        precondition(!gate.acquireCloud(cloud, cancel: {}), "Cloud capture cannot overlap local capture")
        backend.callbacks[0].0("editable local text", false)
        precondition(service.transcript == "editable local text")
        service.stop()
        await localSpeechEventually { timers.pending.last?.0 == .seconds(3) }
        precondition(service.phase == .stopping && !gate.occupied, "Stop ends microphone capture before local finalization")
        timers.wakeLast()
        await localSpeechEventually { service.phase == .finished }
        let stoppedText = service.transcript
        backend.callbacks[0].0("late final must not replace draft", true)
        backend.callbacks[0].1()
        precondition(service.phase == .finished && service.transcript == stoppedText)
        timers.drain()
        for _ in 0..<20 { await Task.yield() }

        service.start()
        await localSpeechEventually { service.phase == .listening && backend.callbacks.count == 2 }
        backend.callbacks[0].0("old generation", true)
        precondition(service.phase == .listening && service.transcript.isEmpty)
        backend.callbacks[1].0(String(repeating: "x", count: 600), false)
        precondition(service.transcript.count == 501 && service.phase == .stopping && service.message.contains("500-character"),
                     "Oversized dictation must stop with visible validation, never silently commit truncated text")
        backend.callbacks[1].0("final local text", true)
        precondition(service.phase == .finished && service.transcript == "final local text" && !gate.occupied)
        timers.drain()
        for _ in 0..<20 { await Task.yield() }

        service.start()
        await localSpeechEventually { service.phase == .listening && backend.callbacks.count == 3 && !timers.pending.isEmpty }
        // Let the replacement capture timer enter the injected scheduler;
        // phase publication precedes the new timer task's first execution.
        for _ in 0..<20 { await Task.yield() }
        precondition(timers.pending.last?.0 == .seconds(30))
        timers.wakeLast()
        await localSpeechEventually { service.phase == .stopping && timers.pending.last?.0 == .seconds(3) }
        timers.wakeLast()
        await localSpeechEventually { service.phase == .finished }
        precondition(!gate.occupied, "Capture and finalization are both bounded")
        timers.drain()
        for _ in 0..<20 { await Task.yield() }

        service.start()
        await localSpeechEventually { service.phase == .listening && backend.callbacks.count == 4 }
        backend.callbacks[3].1()
        precondition(service.phase == .failed && !gate.occupied)
        timers.drain()
        for _ in 0..<20 { await Task.yield() }
        print("Private dictation: unsupported/denied without audio, delayed permissions, admission, capture/finalization bounds, partial/final/error, late callback guards: PASS")
    }
}
