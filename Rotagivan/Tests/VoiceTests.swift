import AppKit
import SwiftUI

@MainActor private final class FakeMicrophone: VoiceAudioCapturing {
    let buffer = VoiceAudioBuffer()
    var starts = 0
    var stops = 0
    func start() throws {
        starts += 1
        buffer.append(Data(repeating: 1, count: 32000), rms: 0.1)
    }
    func stop() { stops += 1 }
}
private final class FakeVoiceCloud: VoiceCloudServing {
    let decision: VoiceDecision
    var delay: UInt64 = 1_000_000
    var requests = 0
    init(_ decision: VoiceDecision) { self.decision = decision }
    func transcribe(_ wav: Data) async throws -> String {
        precondition(String(data: wav.prefix(4), encoding: .ascii) == "RIFF")
        requests += 1
        try await Task.sleep(nanoseconds: delay)
        return "open Slack"
    }
    func classify(_ transcript: String, catalog: [VoiceRegisteredAction]) async throws -> VoiceDecision {
        precondition(transcript == "open Slack")
        return decision
    }
}

@MainActor private final class CloudPreparationGate {
    var pending: [CheckedContinuation<VoiceCloudServing, Never>] = []
    func prepare() async -> VoiceCloudServing {
        await withCheckedContinuation { pending.append($0) }
    }
    func resolve(_ cloud: VoiceCloudServing, at index: Int = 0) {
        pending.remove(at: index).resume(returning: cloud)
    }
}

@MainActor private final class VoicePermissionGate {
    var pending: [CheckedContinuation<Bool, Never>] = []
    func request() async -> Bool { await withCheckedContinuation { pending.append($0) } }
    func resolve(_ allowed: Bool) { pending.removeFirst().resume(returning: allowed) }
}

@MainActor private final class ThrowingVoicePreparationGate {
    var pending: CheckedContinuation<VoiceCloudServing, Error>?
    func prepare() async throws -> VoiceCloudServing {
        try await withCheckedThrowingContinuation { pending = $0 }
    }
    func reject() { let continuation = pending!; pending = nil; continuation.resume(throwing: VoiceError.message("Late fixture error")) }
}

@MainActor private func voiceEventually(_ condition: () -> Bool, _ message: String) async {
    for _ in 0..<2_000 {
        if condition() { return }
        await Task.yield()
    }
    preconditionFailure(message)
}

private final class VoiceTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 100
    func now() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); value += seconds; lock.unlock() }
}

@MainActor private final class ClockMicrophone: VoiceAudioCapturing {
    let buffer: VoiceAudioBuffer
    var starts = 0, stops = 0
    init(clock: VoiceTestClock) { buffer = VoiceAudioBuffer(now: { clock.now() }) }
    func start() throws { starts += 1 }
    func speech() { buffer.append(Data(repeating: 1, count: 32000), rms: 0.1) }
    func stop() { stops += 1 }
}

/// Cancellation requests deliberately do not resume a suspended operation.
/// Tests explicitly drain it, matching transports that acknowledge cancellation
/// later and preventing a Task.cancel-only fixture from hiding overlap.
private final class GatedVoiceCloud: VoiceCloudServing, @unchecked Sendable {
    private enum Response { case text(String), decision(VoiceDecision) }
    private let lock = NSLock()
    private var pending: [(String, CheckedContinuation<Response, Error>)] = []
    private var history: [String] = []
    private var active = 0, maximum = 0, cancellations = 0, closures = 0
    var classificationSteps = 1
    var stages: [String] { lock.lock(); defer { lock.unlock() }; return history }
    var pendingStages: [String] { lock.lock(); defer { lock.unlock() }; return pending.map(\.0) }
    var maxActive: Int { lock.lock(); defer { lock.unlock() }; return maximum }
    var cancelCount: Int { lock.lock(); defer { lock.unlock() }; return cancellations }
    private func gate(_ stage: String) async throws -> Response {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock(); history.append(stage); active += 1; maximum = max(maximum, active)
            pending.append((stage, continuation)); lock.unlock()
        }
    }
    func transcribe(_ wav: Data) async throws -> String {
        precondition(String(data: wav.prefix(4), encoding: .ascii) == "RIFF")
        guard case .text(let value) = try await gate("stt") else { preconditionFailure("Wrong fixture response") }
        return value
    }
    func classify(_ transcript: String, catalog: [VoiceRegisteredAction]) async throws -> VoiceDecision {
        var result: VoiceDecision?
        for _ in 0..<classificationSteps {
            guard case .decision(let value) = try await gate("classify") else { preconditionFailure("Wrong fixture response") }
            result = value
        }
        return result!
    }
    func cancelRequests() { lock.lock(); cancellations += 1; lock.unlock() }
    func close() { lock.lock(); closures += 1; lock.unlock(); cancelRequests() }
    private func resolve(_ result: Result<Response, Error>) {
        lock.lock(); let (_, continuation) = pending.removeFirst(); active -= 1; lock.unlock()
        continuation.resume(with: result)
    }
    func text(_ value: String = "open Slack") { resolve(.success(.text(value))) }
    func decision(_ value: VoiceDecision) { resolve(.success(.decision(value))) }
    func error() { resolve(.failure(VoiceError.message("Fixture connection failed"))) }
}

@main struct VoiceTests {
    @MainActor static func main() async throws {
        let slack = VoiceRegisteredAction(action: .openApp(bundleID: "com.tinyspeck.slackmacgap", name: "Slack"),
                                          detail: "Launch or activate Slack.")
        let mute = VoiceRegisteredAction(action: .media(.mute), detail: "Toggle system output mute.")
        let pause = VoiceRegisteredAction(action: .media(.playPause), detail: "Play or pause media.")
        let catalog = [slack, mute, pause]
        let decision = VoiceDecision(matches: [VoiceMatch(record: slack, probability: 0.85),
            VoiceMatch(record: mute, probability: 0.08), VoiceMatch(record: pause, probability: 0.04)],
            confidence: 0.8, noMatch: false)

        if CommandLine.arguments.contains("--live") {
            guard let path = CommandLine.arguments.last, path.hasSuffix(".wav") else { fatalError("Provide synthetic WAV path") }
            let client = OpenRouterVoiceCloud(key: try OpenRouterCredential.load())
            defer { client.close() }
            let text = try await client.transcribe(Data(contentsOf: URL(fileURLWithPath: path)))
            precondition(text.lowercased().contains("slack"), "Synthetic speech must transcribe Slack")
            let result = try await client.classify(text, catalog: catalog)
            precondition(!result.noMatch && result.matches.first?.id == slack.id)
            print("Live synthetic STT → Jev → registered Slack ID: PASS")
            return
        }

        precondition(OpenRouterCredential.parse("OTHER=secret\nexport OPENROUTER_API_KEY='test-key' # comment") == "test-key")
        precondition(OpenRouterCredential.parse("OPENROUTER_API_KEY=first\nOPENROUTER_API_KEY=\"second\"") == "second")
        precondition(OpenRouterCredential.parse("# OPENROUTER_API_KEY=hidden") == nil)
        precondition(OpenRouterCredential.parse("OPENROUTER_API_KEY='unterminated") == nil)
        precondition(OpenRouterCredential.parse("OPENROUTER_API_KEY='$(literal)'") == "$(literal)")
        func response(_ probabilities: [String: Double], choice: String = slack.id, confidence: Double = 0.8) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["answers": ["action": ["type": "choice", "choice": choice,
                "confidence": confidence, "probabilities": probabilities]]])
        }
        let valid = [slack.id: 0.85, mute.id: 0.08, pause.id: 0.04, "none": 0.03]
        let parsed = try VoiceDecision.decode(response(valid), catalog: catalog)
        precondition(parsed.matches.map(\.id) == [slack.id, mute.id, pause.id])
        precondition(parsed.matches[0].probability == 0.85, "Do not renormalize top three")
        for invalid in [
            [slack.id: 0.8, mute.id: 0.1, "unknown": 0.05, "none": 0.05],
            [slack.id: 1.2, mute.id: 0, pause.id: 0, "none": 0],
            [slack.id: 0.1, mute.id: 0.1, pause.id: 0.1, "none": 0.1]
        ] {
            do { _ = try VoiceDecision.decode(response(invalid), catalog: catalog); fatalError("Accepted invalid decision") } catch {}
        }
        do { _ = try VoiceDecision.decode(response(valid, choice: mute.id), catalog: catalog); fatalError("Accepted inconsistent choice") } catch {}
        let noMatch = try VoiceDecision.decode(response([slack.id: 0.1, mute.id: 0.05, pause.id: 0.05, "none": 0.8], choice: "none"), catalog: catalog)
        precondition(noMatch.noMatch)
        let pcm = Data(repeating: 0, count: 32000)
        let wav = VoiceAudioBuffer.wav(pcm)
        precondition(wav.count == 32044 && String(data: wav[8..<12], encoding: .ascii) == "WAVE")
        let bounded = VoiceAudioBuffer()
        bounded.append(Data(repeating: 0, count: VoiceAudioBuffer.maximumBytes + 100), rms: 0)
        precondition(bounded.snapshot().0.count == VoiceAudioBuffer.maximumBytes)
        bounded.clear(); precondition(bounded.snapshot().0.isEmpty)

        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let suite = "Rotagivan.VoiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: "migration.rotagivan.v1")
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        var catalogSettings = store.settings
        let triggerOnly = RecordedShortcut(keyCode: 98, modifiers: (1 << 20) | (1 << 19), keyLabel: "VOICE TRIGGER ONLY")
        catalogSettings.actionBindings = [ActionBinding(trigger: BindingTrigger(keyboard: triggerOnly), action: slack.action)]
        let registry = VoiceActionRegistry.make(settings: catalogSettings,
            applications: [ExplorerApplication(bundleID: "com.tinyspeck.slackmacgap", name: "Slack", url: URL(fileURLWithPath: "/Applications/Slack.app"))])
        precondition(!registry.contains { $0.action == .keystroke(triggerOnly) }, "Input hotkeys are not output actions")
        precondition(Set(registry.map(\.id)).count == registry.count)
        precondition(registry.contains { $0.id == slack.id })
        precondition(registry.allSatisfy { !$0.detail.isEmpty && $0.action.isValid })
        precondition(registry.contains { $0.action == .media(.playPause) })
        precondition(VoiceRegisteredAction.id(for: slack.action) == slack.id)

        let fake = FakeVoiceCloud(decision)
        let mic = FakeMicrophone()
        let session = VoiceSession()
        session.makeCloud = { fake }; session.makeMicrophone = { mic }; session.requestPermission = { true }
        session.start(catalog: catalog)
        try await Task.sleep(nanoseconds: 30_000_000)
        precondition(session.phase == .listening && mic.starts == 1)
        try await Task.sleep(nanoseconds: 80_000_000)
        precondition(session.waveform.contains { $0 > 0 }, "Live microphone levels reach the HUD")
        precondition(session.selectedMatch == nil, "No execution while recording")
        session.finishListening()
        precondition(mic.stops == 1 && mic.buffer.snapshot().0.isEmpty)
        try await Task.sleep(nanoseconds: 50_000_000)
        precondition(session.phase == .ready && session.transcript == "open Slack")
        precondition(session.selectedMatch?.id == slack.id)
        session.select(.right); precondition(session.selectedMatch?.id == mute.id)
        session.select(.down); precondition(session.selectedMatch?.id == pause.id)
        session.select(.left); precondition(session.selectedMatch == nil)
        session.cancel()
        precondition(session.phase == .cancelled && session.transcript.isEmpty && session.decision == nil)
        session.receive(decision, final: true)
        precondition(session.phase == .cancelled, "Late results cannot resurrect a closed session")

        let denied = VoiceSession()
        let unusedMic = FakeMicrophone()
        denied.makeCloud = { fake }; denied.makeMicrophone = { unusedMic }; denied.requestPermission = { false }
        denied.start(catalog: catalog)
        try await Task.sleep(nanoseconds: 30_000_000)
        precondition(denied.phase == .failed && unusedMic.starts == 0)
        denied.cancel()
        let cancelled = VoiceSession()
        cancelled.makeCloud = { fake }; cancelled.makeMicrophone = { unusedMic }
        cancelled.requestPermission = { try? await Task.sleep(nanoseconds: 30_000_000); return true }
        cancelled.start(catalog: catalog)
        await Task.yield(); cancelled.cancel()
        try await Task.sleep(nanoseconds: 60_000_000)
        precondition(unusedMic.starts == 0, "Cancellation during permission must not open microphone")

        let credentialGate = CloudPreparationGate()
        let credentialSession = VoiceSession()
        let credentialMic = FakeMicrophone()
        let lateCloud = FakeVoiceCloud(decision)
        var permissionRequests = 0
        credentialSession.makeCloud = { await credentialGate.prepare() }
        credentialSession.makeMicrophone = { credentialMic }
        credentialSession.requestPermission = { permissionRequests += 1; return true }
        credentialSession.start(catalog: catalog)
        await Task.yield()
        precondition(credentialGate.pending.count == 1 && credentialSession.phase == .preparing)
        precondition(credentialSession.message.contains("credentials") && permissionRequests == 0 && credentialMic.starts == 0)
        credentialSession.cancel()
        credentialGate.resolve(lateCloud)
        try await Task.sleep(nanoseconds: 20_000_000)
        precondition(credentialSession.phase == .cancelled && permissionRequests == 0 && credentialMic.starts == 0,
            "Cancelled credential preparation cannot request permission or start recording")
        credentialSession.start(catalog: catalog)
        await Task.yield()
        credentialSession.start(catalog: catalog)
        await Task.yield()
        precondition(credentialGate.pending.count == 2)
        let currentCloud = FakeVoiceCloud(decision)
        credentialGate.resolve(currentCloud, at: 1)
        try await Task.sleep(nanoseconds: 20_000_000)
        precondition(credentialSession.phase == .listening && permissionRequests == 1 && credentialMic.starts == 1)
        credentialGate.resolve(lateCloud)
        try await Task.sleep(nanoseconds: 20_000_000)
        precondition(permissionRequests == 1 && credentialMic.starts == 1,
            "A restarted session must ignore its previous late credential result")
        credentialSession.finishListening()
        try await Task.sleep(nanoseconds: 50_000_000)
        precondition(currentCloud.requests == 1 && lateCloud.requests == 0 && credentialSession.phase == .ready,
            "Late credential results must not replace the current session's cloud client")
        credentialSession.cancel()
        let busySession = VoiceSession()
        busySession.makeCloud = { throw VoiceError.message(CredentialWorkerError.busy.localizedDescription) }
        busySession.makeMicrophone = { credentialMic }
        busySession.requestPermission = { permissionRequests += 1; return true }
        busySession.start(catalog: catalog)
        try await Task.sleep(nanoseconds: 20_000_000)
        precondition(busySession.phase == .failed && busySession.message.contains("Keychain operation") && permissionRequests == 1,
            "Busy credential work must show an actionable failure before permission or microphone access")
        busySession.cancel()

        // Failure, unlike user cancellation, must also revoke suspended
        // preparation's authority to ask permission or open the microphone.
        let failedPreparation = VoiceSession()
        let failedCloudGate = CloudPreparationGate()
        let failedMic = FakeMicrophone()
        var failedPermissionRequests = 0
        failedPreparation.makeCloud = { await failedCloudGate.prepare() }
        failedPreparation.makeMicrophone = { failedMic }
        failedPreparation.requestPermission = { failedPermissionRequests += 1; return true }
        failedPreparation.start(catalog: catalog)
        await voiceEventually({ failedCloudGate.pending.count == 1 }, "Cloud preparation must suspend")
        failedPreparation.fail(VoiceError.message("Fixture connection failed. Nothing was run."))
        failedCloudGate.resolve(FakeVoiceCloud(decision))
        for _ in 0..<20 { await Task.yield() }
        precondition(failedPreparation.phase == .failed && failedPermissionRequests == 0 && failedMic.starts == 0,
            "Late successful cloud preparation must not resurrect a failed session")
        let permissionGate = VoicePermissionGate()
        failedPreparation.makeCloud = { fake }
        failedPreparation.requestPermission = { await permissionGate.request() }
        failedPreparation.start(catalog: catalog)
        await voiceEventually({ permissionGate.pending.count == 1 }, "Permission preparation must suspend")
        failedPreparation.fail(VoiceError.message("Fixture preparation expired. Nothing was run."))
        permissionGate.resolve(true)
        for _ in 0..<20 { await Task.yield() }
        precondition(failedPreparation.phase == .failed && failedMic.starts == 0,
            "Late permission grant must not open the microphone after failure")
        failedPreparation.cancel()
        let latePreparationError = ThrowingVoicePreparationGate()
        failedPreparation.makeCloud = { try await latePreparationError.prepare() }
        failedPreparation.start(catalog: catalog)
        await voiceEventually({ latePreparationError.pending != nil }, "Throwing preparation must suspend")
        failedPreparation.fail(VoiceError.message("Current failure"))
        latePreparationError.reject()
        for _ in 0..<20 { await Task.yield() }
        precondition(failedPreparation.phase == .failed && failedPreparation.message == "Current failure" && failedMic.starts == 0,
            "Late preparation errors cannot replace the current failure")
        failedPreparation.cancel()

        let immutableFinal = VoiceSession()
        var finalCallbacks = 0
        immutableFinal.onFinalMatch = { finalCallbacks += 1 }
        immutableFinal.receive(decision, final: true)
        immutableFinal.receive(noMatch, final: false)
        immutableFinal.receive(noMatch, final: true)
        precondition(immutableFinal.phase == .ready && immutableFinal.selectedMatch?.id == slack.id && finalCallbacks == 1,
            "A committed final decision is immutable under late partial or duplicate-final events")
        immutableFinal.cancel()

        func timedVoice(admission: VoicePipelineAdmission? = nil) -> (VoiceSession, ClockMicrophone, GatedVoiceCloud, VoiceTestClock) {
            let clock = VoiceTestClock(), cloud = GatedVoiceCloud()
            let microphone = ClockMicrophone(clock: clock), voice = VoiceSession()
            voice.now = { clock.now() }; voice.automaticTicks = false
            voice.finalMatchingBudget = 3
            voice.pipelineAdmission = admission ?? VoicePipelineAdmission()
            voice.makeCloud = { cloud }; voice.makeMicrophone = { microphone }; voice.requestPermission = { true }
            return (voice, microphone, cloud, clock)
        }
        func listening(_ voice: VoiceSession) async {
            voice.start(catalog: catalog)
            await voiceEventually({ voice.phase == .listening }, "Synthetic voice must reach listening")
        }
        func partial(_ voice: VoiceSession, _ microphone: ClockMicrophone, _ clock: VoiceTestClock) {
            clock.advance(0.75); microphone.speech(); voice.tick()
        }
        // Final audio preempts either stage, but never starts another request
        // until a cancellation-ignoring old transport actually returns.
        for heldStage in ["stt", "classify"] {
            let (voice, microphone, cloud, clock) = timedVoice()
            await listening(voice); partial(voice, microphone, clock)
            await voiceEventually({ cloud.pendingStages == ["stt"] }, "Partial STT must start")
            if heldStage == "classify" {
                cloud.text()
                await voiceEventually({ cloud.pendingStages == ["classify"] }, "Partial classification must start")
            }
            voice.finishListening()
            await voiceEventually({ cloud.cancelCount > 0 }, "Final audio must promptly cancel the partial transport")
            for _ in 0..<20 { await Task.yield() }
            precondition(cloud.stages.filter { $0 == "stt" }.count == 1 && cloud.maxActive == 1,
                "Task cancellation is not transport drain; final STT cannot overlap the held partial")
            if heldStage == "stt" { cloud.text("stale partial") } else { cloud.decision(noMatch) }
            await voiceEventually({ cloud.pendingStages == ["stt"] }, "Final STT must start immediately after drain")
            precondition(voice.transcript != "stale partial" && voice.decision == nil,
                "Superseded partial success cannot publish after final audio")
            cloud.text()
            await voiceEventually({ cloud.pendingStages == ["classify"] }, "Final classification must start")
            cloud.decision(decision)
            await voiceEventually({ voice.phase == .ready }, "Final decision must publish")
            precondition(cloud.maxActive == 1 && microphone.stops == 1 && microphone.buffer.snapshot().0.isEmpty)
            voice.cancel()
        }
        // One deadline covers cancellation drain and every serial classification
        // step, rather than resetting a fresh budget per request.
        for deadlineStage in ["drain", "classification"] {
            let (voice, microphone, cloud, clock) = timedVoice()
            await listening(voice); partial(voice, microphone, clock)
            await voiceEventually({ cloud.pendingStages == ["stt"] }, "Deadline fixture partial must start")
            voice.finishListening()
            if deadlineStage == "classification" {
                cloud.error()
                await voiceEventually({ cloud.pendingStages == ["stt"] }, "Final must follow drained partial")
                cloud.classificationSteps = 3
                cloud.text()
                await voiceEventually({ cloud.pendingStages == ["classify"] }, "Serial classification must start")
                clock.advance(1); cloud.decision(decision)
                await voiceEventually({ cloud.pendingStages == ["classify"] }, "Second classification step must start")
                clock.advance(1); cloud.decision(decision)
                await voiceEventually({ cloud.pendingStages == ["classify"] }, "Third classification step must start")
                clock.advance(1.01)
            } else { clock.advance(3.01) }
            voice.tick()
            precondition(voice.phase == .failed && voice.selectedMatch == nil,
                "Whole final deadline must expire during \(deadlineStage)")
            let failure = voice.message
            if deadlineStage == "classification" { cloud.decision(decision) } else { cloud.error() }
            for _ in 0..<30 { await Task.yield() }
            precondition(voice.phase == .failed && voice.message == failure && voice.decision == nil,
                "Late result after final timeout cannot overwrite failure")
            precondition(cloud.maxActive == 1)
            voice.cancel()
        }
        for heldStage in ["stt", "classify"] {
            for termination in ["fail-success", "fail-error", "cancel-success", "cancel-error"] {
                let (voice, microphone, cloud, _) = timedVoice()
                await listening(voice); microphone.speech(); voice.finishListening()
                await voiceEventually({ cloud.pendingStages == ["stt"] }, "Final failure fixture must suspend")
                if heldStage == "classify" {
                    cloud.text(); await voiceEventually({ cloud.pendingStages == ["classify"] }, "Final classification must suspend")
                }
                if termination.hasPrefix("fail") { voice.fail(VoiceError.message("Current fixture failure")) }
                else { voice.cancel() }
                let phase = voice.phase, message = voice.message, transcript = voice.transcript
                if termination.hasSuffix("error") { cloud.error() }
                else if heldStage == "stt" { cloud.text("late obsolete transcript") }
                else { cloud.decision(decision) }
                for _ in 0..<30 { await Task.yield() }
                precondition(voice.phase == phase && voice.message == message && voice.transcript == transcript && voice.decision == nil,
                    "Late \(heldStage) \(termination) must not mutate a terminated session")
                voice.cancel()
            }
        }
        for boundary in ["stt", "classify"] {
            let (voice, microphone, cloud, _) = timedVoice()
            var currentCatalog = true
            voice.isCatalogCurrent = { _ in currentCatalog }
            await listening(voice); microphone.speech(); voice.finishListening()
            await voiceEventually({ cloud.pendingStages == ["stt"] }, "Catalog boundary STT must suspend")
            if boundary == "classify" {
                cloud.text(); await voiceEventually({ cloud.pendingStages == ["classify"] }, "Catalog boundary classification must suspend")
            }
            currentCatalog = false
            if boundary == "stt" { cloud.text() } else { cloud.decision(decision) }
            await voiceEventually({ voice.phase == .failed }, "Changed catalog must fail at the \(boundary) response boundary")
            precondition(voice.selectedMatch == nil && voice.decision == nil && voice.message.contains("changed"))
            voice.cancel()
        }
        for boundary in ["stt", "classify"] {
            let (voice, microphone, cloud, clock) = timedVoice()
            await listening(voice); microphone.speech(); voice.finishListening()
            await voiceEventually({ cloud.pendingStages == ["stt"] }, "Deadline boundary STT must suspend")
            if boundary == "classify" {
                cloud.text(); await voiceEventually({ cloud.pendingStages == ["classify"] }, "Deadline boundary classification must suspend")
            }
            clock.advance(3.01)
            // Do not call tick: each response boundary must enforce the same
            // monotonic deadline even if UI/timer servicing was delayed.
            if boundary == "stt" { cloud.text() } else { cloud.decision(decision) }
            await voiceEventually({ voice.phase == .failed }, "Expired \(boundary) response must enforce the final deadline without a timer tick")
            precondition(voice.decision == nil && voice.selectedMatch == nil && voice.message.contains("timed out"))
            voice.cancel()
        }
        // AppExplorer retries create distinct sessions. Admission must remain
        // held across instances until the old transport drains, even after quit.
        let sharedAdmission = VoicePipelineAdmission()
        let (oldVoice, oldMic, oldCloud, oldClock) = timedVoice(admission: sharedAdmission)
        await listening(oldVoice); partial(oldVoice, oldMic, oldClock)
        await voiceEventually({ oldCloud.pendingStages == ["stt"] }, "Old session request must suspend")
        oldVoice.cancel()
        let (newVoice, newMic, newCloud, newClock) = timedVoice(admission: sharedAdmission)
        newVoice.start(catalog: catalog)
        precondition(newVoice.phase == .failed && newMic.starts == 0 && newCloud.stages.isEmpty,
            "A new VoiceSession cannot bypass drain or reopen the microphone while the previous transport is stopping")
        oldCloud.text("late old speech")
        await voiceEventually({ !sharedAdmission.occupied }, "Old transport must actually drain before retry admission")
        await listening(newVoice); newMic.speech(); newVoice.finishListening()
        await voiceEventually({ newCloud.pendingStages == ["stt"] }, "Retry must proceed once old transport drains")
        precondition(oldVoice.phase == .cancelled && oldVoice.transcript.isEmpty && oldVoice.decision == nil)
        newClock.advance(3.01); newVoice.tick()
        precondition(newVoice.phase == .failed)
        newCloud.error()
        for _ in 0..<30 { await Task.yield() }
        newVoice.cancel()

        // Continuous newer snapshots are coalesced, not an excuse to starve
        // completed provisional results while the user is still speaking.
        let (liveVoice, liveMic, liveCloud, liveClock) = timedVoice()
        await listening(liveVoice); partial(liveVoice, liveMic, liveClock)
        await voiceEventually({ liveCloud.pendingStages == ["stt"] }, "Live partial must start")
        for _ in 0..<3 { liveClock.advance(1.21); liveMic.speech(); liveVoice.tick() }
        liveCloud.text("first live command")
        await voiceEventually({ liveCloud.pendingStages == ["classify"] }, "Completed partial must classify despite newer snapshots")
        liveCloud.decision(decision)
        await voiceEventually({ liveVoice.decision?.matches.first?.id == slack.id }, "Live provisional candidates must progress")
        precondition(liveVoice.phase == .listening && liveVoice.selectedMatch == nil)
        await voiceEventually({ liveCloud.pendingStages == ["stt"] }, "Only newest coalesced partial must follow")
        precondition(liveCloud.stages.filter { $0 == "stt" }.count == 2 && liveCloud.maxActive == 1)
        liveClock.advance(1.21); liveMic.speech(); liveVoice.tick()
        liveCloud.text("second live command")
        await voiceEventually({ liveCloud.pendingStages == ["classify"] }, "Next completed provisional must classify")
        let secondLive = VoiceDecision(matches: [VoiceMatch(record: mute, probability: 1)], confidence: 1, noMatch: false)
        liveCloud.decision(secondLive)
        await voiceEventually({ liveVoice.decision?.matches.first?.id == mute.id }, "Newer completed provisional must advance the visible candidate")
        await voiceEventually({ liveCloud.pendingStages == ["stt"] }, "Coalesced third partial must follow")
        liveCloud.text("second live command")
        await voiceEventually({ liveCloud.pendingStages.isEmpty }, "Duplicate provisional transcript must finish without another classifier")
        for _ in 0..<20 { await Task.yield() }
        precondition(liveCloud.stages.filter { $0 == "classify" }.count == 2 && liveVoice.decision?.matches.first?.id == mute.id,
            "Identical partial transcripts must reuse the last successful provisional classification")
        liveMic.speech(); liveVoice.finishListening()
        await voiceEventually({ liveCloud.pendingStages == ["stt"] }, "Final audio must still transcribe after partial dedup")
        liveCloud.text("second live command")
        await voiceEventually({ liveCloud.pendingStages == ["classify"] }, "Final transcript must always classify even if its text repeats")
        liveVoice.cancel(); liveCloud.error()
        for _ in 0..<30 { await Task.yield() }
        precondition(liveVoice.phase == .cancelled && liveVoice.decision == nil)

        // Exercise the real endpoint branch, without wall-clock sleeps or input.
        for endpoint in ["no-speech", "silence", "recording-limit"] {
            let (voice, microphone, cloud, clock) = timedVoice()
            await listening(voice)
            if endpoint == "no-speech" {
                clock.advance(5.01); voice.tick()
                precondition(voice.phase == .failed && voice.message.contains("No speech") && cloud.stages.isEmpty)
            } else {
                microphone.speech(); clock.advance(endpoint == "silence" ? 0.86 : 12.01)
                if endpoint == "recording-limit" { microphone.speech() }
                voice.tick()
                precondition(voice.phase == .matching && microphone.stops == 1)
                await voiceEventually({ cloud.pendingStages == ["stt"] }, "Actual endpoint must dispatch final audio")
                cloud.text(); await voiceEventually({ cloud.pendingStages == ["classify"] }, "Endpoint final must classify")
                cloud.decision(noMatch); await voiceEventually({ voice.phase == .ready }, "Endpoint no-match must complete")
                precondition(voice.selectedMatch == nil)
            }
            voice.cancel()
        }

        let vaultServer = "https://fixture.invalid"
        let vaultUser = "fixture-user"
        let master = VaultCrypto.randomMaster()
        let record = try VaultCrypto.seal(VaultPayload(openRouterAPIKey: "fixture-key"), master: master,
            userID: vaultUser, vaultID: UUID().uuidString, revision: 1)
        var local = VaultLocal.fresh(); local.masterKey = master; local.cached = record
        let fixtureLocal = local
        VaultKeychain.setActive(server: vaultServer, userID: vaultUser)
        do {
            _ = try VaultKeychain.currentAPIKey()
            fatalError("Locked cache must require explicit unlock")
        } catch { precondition(error.localizedDescription.contains("Unlock API keys")) }
        VaultKeychain.cache(fixtureLocal, server: vaultServer, userID: vaultUser)
        for _ in 0..<20 {
            let cachedKey = try VaultKeychain.currentAPIKey()
            precondition(cachedKey == "fixture-key", "Repeated voice starts reuse cached credentials without Security calls")
        }
        let fixtureKey = try VaultKeychain.currentAPIKey(readLocal: { _, _ in fixtureLocal })
        precondition(fixtureKey == "fixture-key")
        do {
            _ = try VaultKeychain.currentAPIKey(readLocal: { _, _ in
                VaultKeychain.setActive(server: vaultServer, userID: nil)
                VaultKeychain.setActive(server: vaultServer, userID: vaultUser)
                return fixtureLocal
            })
            fatalError("Accepted credential result across same-account sign-out/sign-in")
        } catch { precondition(error.localizedDescription.contains("active account changed")) }
        do {
            _ = try VaultKeychain.currentAPIKey(readLocal: { _, _ in
                VaultKeychain.setActive(server: vaultServer, userID: "different-user")
                return nil
            })
            fatalError("Accepted missing-vault result after account change")
        } catch { precondition(error.localizedDescription.contains("active account changed")) }
        VaultKeychain.setActive(server: vaultServer, userID: nil)

        let controller = AppExplorerController(defaults: defaults)
        controller.configuration = { AppExplorerSettings() }
        var initialFrontApp = "com.apple.finder"
        controller.frontmostPID = { 4242 }; controller.frontmostBundleID = { initialFrontApp }
        controller.contextIsValid = { true }
        var available = catalog
        controller.voiceCatalog = { available }
        controller.prepareVoice = { voice, records in
            precondition(voice.isCatalogCurrent(records), "Controller must accept its actual current catalog snapshot")
            let original = available
            available[0].keywordSets = [["changed vocabulary"]]
            precondition(!voice.isCatalogCurrent(records), "Controller must revalidate learned vocabulary, not only IDs")
            available = original
            available[0] = VoiceRegisteredAction(action: original[0].action, detail: "Changed description")
            precondition(available[0].id == original[0].id && !voice.isCatalogCurrent(records),
                "Description edits must invalidate the actual controller snapshot despite stable IDs")
            available = original
            available[0] = VoiceRegisteredAction(action: pause.action, detail: original[0].detail)
            precondition(!voice.isCatalogCurrent(records), "Output changes must invalidate the controller snapshot")
            available = original
            initialFrontApp = "fixture.otherApp"
            precondition(!voice.isCatalogCurrent(records), "Actual frontmost application changes must invalidate preparation")
            initialFrontApp = "com.apple.finder"
            precondition(voice.isCatalogCurrent(records))
            voice.receive(decision, final: true)
        }
        var executed: [BindingAction] = []
        controller.onKeyboardBindingAction = { executed.append($0) }
        func key(_ code: UInt16, repeatKey: Bool = false) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: repeatKey, keyCode: code)!
        }
        func report(_ touching: Bool, x: Double = 500, y: Double = 500) -> TrackpadReport {
            TrackpadReport(contacts: touching ? [FingerContact(id: 1, x: x, y: y, touching: true, confident: true)] : [],
                           buttonDown: false, scanTime: 0)
        }
        controller.show(waitingForLift: false)
        controller.centerTap()
        precondition(controller.displayedVoiceSession != nil, "Main center tap activates voice")
        controller.process(report(true))
        controller.process(report(true, x: 600))
        precondition(controller.displayedVoiceSession?.selected == .right)
        precondition(executed.isEmpty && controller.isVisible, "Highlight alone must not execute")
        precondition(controller.processLayerKey(key(49, repeatKey: true)))
        precondition(executed.isEmpty)
        controller.process(report(false))
        controller.process(report(false))
        try await Task.sleep(nanoseconds: 80_000_000)
        precondition(executed == [mute.action] && !controller.isVisible, "Swipe release executes selected ID exactly once without Enter")

        controller.show(waitingForLift: false); controller.centerTap()
        precondition(controller.processLayerKey(key(36)))
        try await Task.sleep(nanoseconds: 80_000_000)
        precondition(executed == [mute.action, slack.action], "Enter executes default top match")
        controller.show(waitingForLift: false); controller.centerTap()
        available = [mute, pause]
        precondition(controller.processLayerKey(key(36)))
        precondition(controller.displayedVoiceSession?.phase == .failed && executed.count == 2, "Removed IDs fail closed")
        controller.dismiss(); available = catalog
        controller.show(waitingForLift: false); controller.centerTap()
        controller.displayedVoiceSession?.select(.left)
        controller.confirmVoiceAction()
        precondition(controller.isVisible && controller.displayedVoiceSession == nil && executed.count == 2)
        controller.dismiss()
        controller.prepareVoice = { voice, _ in voice.receive(noMatch, final: true) }
        controller.show(waitingForLift: false); controller.centerTap()
        controller.displayedVoiceSession?.select(.up)
        controller.confirmVoiceAction()
        precondition(executed.count == 2, "No-match results cannot execute even if an action is selected")
        controller.dismiss()

        // Exercise the real controller's four-sector report path, including
        // every result, inversion, failures, retry, and readiness races.
        let gestureController = AppExplorerController(defaults: defaults)
        var pickerInverted = false
        gestureController.configuration = { AppExplorerSettings(invertPickerDirection: pickerInverted) }
        gestureController.frontmostPID = { 4242 }
        gestureController.frontmostBundleID = { "com.apple.finder" }
        gestureController.contextIsValid = { true }
        var gestureCatalog = catalog
        gestureController.voiceCatalog = { gestureCatalog }
        gestureController.prepareVoice = { voice, _ in voice.receive(decision, final: true) }
        var gestureExecuted: [BindingAction] = []
        gestureController.onKeyboardBindingAction = { gestureExecuted.append($0) }
        func move(_ dx: Double, _ dy: Double) {
            gestureController.process(report(true))
            gestureController.process(report(true, x: 500 + dx, y: 500 + dy))
        }
        for inverted in [false, true] {
            pickerInverted = inverted
            let sign = inverted ? -1.0 : 1.0
            for (index, delta) in [(0, (0.0, -100.0)), (1, (100.0, 0.0)), (2, (0.0, 100.0))] {
                gestureController.show(waitingForLift: false); gestureController.beginVoiceMode()
                let count = gestureExecuted.count
                move(delta.0 * sign, delta.1 * sign)
                precondition(gestureExecuted.count == count, "Movement only highlights")
                gestureController.process(report(false)); gestureController.process(report(false))
                try await Task.sleep(nanoseconds: 80_000_000)
                precondition(gestureExecuted.count == count + 1 && gestureExecuted.last == decision.matches[index].record.action,
                    "Each directional result must execute once on lift, respecting picker inversion")
            }
        }
        pickerInverted = false
        let gestureCount = gestureExecuted.count
        for state in ["ready", "no-match", "failed", "preparing"] {
            gestureController.prepareVoice = { voice, _ in
                if state == "ready" { voice.receive(decision, final: true) }
                if state == "no-match" { voice.receive(noMatch, final: true) }
                if state == "failed" { voice.fail(VoiceError.message("No speech recognized")) }
            }
            gestureController.show(waitingForLift: false); gestureController.beginVoiceMode()
            move(-100, 0); gestureController.process(report(false))
            precondition(gestureController.displayedVoiceSession == nil && gestureController.isVisible,
                "Left swipe must leave voice mode even with no speech or while preparing")
            gestureController.dismiss()
        }
        var retries = 0
        gestureController.prepareVoice = { voice, _ in retries += 1; voice.fail(VoiceError.message("No speech recognized")) }
        gestureController.show(waitingForLift: false); gestureController.beginVoiceMode()
        gestureController.process(report(true)); gestureController.process(report(false))
        precondition(retries == 2, "A center tap after failure must retry without keyboard input")
        gestureController.dismiss()
        gestureController.prepareVoice = { _, _ in }
        gestureController.show(waitingForLift: false); gestureController.beginVoiceMode()
        move(0, -100)
        gestureController.displayedVoiceSession!.receive(decision, final: true)
        gestureController.process(report(false))
        precondition(gestureExecuted.count == gestureCount && gestureController.displayedVoiceSession != nil,
            "Results arriving during a swipe must not turn a disabled tile into an armed action")
        gestureController.dismiss()
        gestureController.prepareVoice = { voice, _ in voice.receive(decision, final: true) }
        gestureController.show(waitingForLift: false); gestureController.beginVoiceMode()
        move(0, -100); gestureCatalog = []
        gestureController.process(report(false))
        precondition(gestureController.displayedVoiceSession?.phase == .failed && gestureExecuted.count == gestureCount,
            "Swipe execution must revalidate the action catalog")
        gestureController.dismiss(); gestureCatalog = catalog

        precondition(!AppExplorerSettings().resolvedVoiceAutoDecide)
        var automatic = AppExplorerSettings()
        automatic.voiceAutoDecide = true
        let restored = try JSONDecoder().decode(AppExplorerSettings.self, from: JSONEncoder().encode(automatic))
        precondition(restored.resolvedVoiceAutoDecide)
        controller.configuration = { automatic }
        controller.prepareVoice = { voice, _ in voice.receive(decision, final: false) }
        controller.show(waitingForLift: false); controller.beginVoiceMode()
        precondition(executed.count == 2, "Partial results never auto-execute")
        let automaticSession = controller.displayedVoiceSession!
        automaticSession.receive(decision, final: true)
        automaticSession.receive(decision, final: true)
        try await Task.sleep(nanoseconds: 80_000_000)
        precondition(executed.count == 3 && executed.last == slack.action, "Auto-decide runs the best final action once")
        controller.prepareVoice = { voice, _ in voice.receive(noMatch, final: true) }
        controller.show(waitingForLift: false); controller.beginVoiceMode()
        precondition(executed.count == 3 && controller.displayedVoiceSession != nil, "Auto-decide must not execute no-match")
        controller.dismiss()
        controller.prepareVoice = { voice, _ in
            available = [mute, pause]
            voice.receive(decision, final: true)
        }
        controller.show(waitingForLift: false); controller.beginVoiceMode()
        precondition(executed.count == 3 && controller.displayedVoiceSession?.phase == .failed, "Auto-decide revalidates removed IDs")
        controller.dismiss(); available = catalog
        // Activation is one ordinary action, regardless of binding or tile input.
        let activation = BindingAction.command(.activateVoiceMode)
        let activationKey = RecordedShortcut(keyCode: 8, modifiers: 1 << 20, keyLabel: "C")
        var activationSettings = AppExplorerSettings()
        activationSettings.actionBindings = [ActionBinding(trigger: BindingTrigger(keyboard: activationKey), action: activation),
            ActionBinding(trigger: BindingTrigger(gesture: .oneFingerTap), action: activation)]
        activationSettings.favorites = [activation.favorite(at: .up)!]
        activationSettings.favorites[0].activationShortcut = RecordedShortcut(keyCode: 9, modifiers: 0, keyLabel: "V")
        controller.configuration = { activationSettings }
        var starts = 0
        controller.prepareVoice = { _, records in
            starts += 1
            precondition(!records.contains { $0.action == activation }, "Voice activation cannot recursively match itself")
        }
        controller.show(waitingForLift: false)
        let activationEvent = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: 0, context: nil, characters: "c", charactersIgnoringModifiers: "c",
            isARepeat: false, keyCode: 8)!
        precondition(controller.processLayerKey(activationEvent))
        precondition(starts == 1 && controller.isVisible && controller.displayedVoiceSession != nil)
        controller.activateVoiceMode()
        precondition(starts == 1, "Repeated activation cannot open a second microphone")
        controller.dismiss()
        controller.show(waitingForLift: false)
        controller.process(report(true)); controller.process(report(true, y: 400)); controller.process(report(false))
        precondition(starts == 2 && controller.displayedVoiceSession != nil, "A tile starts voice without closing the HUD")
        controller.dismiss()
        controller.show(waitingForLift: false)
        controller.process(report(true)); controller.process(report(false))
        try await Task.sleep(nanoseconds: 400_000_000)
        precondition(starts == 3 && controller.displayedVoiceSession != nil, "A tap binding starts voice")
        controller.dismiss()
        precondition(!AppExplorerSettings().resolvedVoiceAutoStart)
        activationSettings.voiceAutoStart = true
        let restoredAutoStart = try JSONDecoder().decode(AppExplorerSettings.self, from: JSONEncoder().encode(activationSettings))
        precondition(restoredAutoStart.resolvedVoiceAutoStart && !restoredAutoStart.resolvedVoiceAutoDecide)
        controller.show(waitingForLift: false)
        precondition(starts == 4 && controller.displayedVoiceSession != nil, "Main HUD opening auto-starts only when opted in")
        controller.show(waitingForLift: false)
        precondition(starts == 4, "Re-presenting a visible HUD does not restart recording")
        controller.endVoiceMode(); controller.switchLayer(nil)
        precondition(starts == 4 && controller.displayedVoiceSession == nil, "Layer navigation does not auto-start voice")
        controller.dismiss()
        controller.showWindowManager(waitingForLift: false)
        precondition(starts == 4 && controller.displayedVoiceSession == nil, "Window Manager does not auto-start voice")
        controller.dismiss()
        let levels = VoiceAudioBuffer()
        for _ in 0..<100 { levels.append(Data(), rms: 0.1) }
        precondition(levels.waveform().count == 48 && levels.waveform().allSatisfy { $0 > 0 && $0 <= 1 })
        levels.append(Data(), rms: .nan)
        precondition(levels.waveform().last == 0)
        levels.clear()
        precondition(levels.waveform().allSatisfy { $0 == 0 })

        controller.configuration = { AppExplorerSettings() }
        let scoped = VoiceActionRegistry.slackDefaults.first { $0.title == "Activity" }!
        var frontApp = "com.tinyspeck.slackmacgap"
        controller.frontmostBundleID = { frontApp }
        available = [scoped]
        controller.prepareVoice = { voice, _ in
            voice.receive(VoiceDecision(matches: [VoiceMatch(record: scoped, probability: 1)], confidence: 1, noMatch: false), final: true)
        }
        controller.show(waitingForLift: false); controller.beginVoiceMode()
        frontApp = "com.apple.finder"
        controller.confirmVoiceAction()
        precondition(executed.count == 3 && controller.displayedVoiceSession?.phase == .failed, "Application actions cannot execute after switching apps")
        controller.dismiss()

        // Custom command IDs are stable while their output changes. Revalidate
        // the complete output and scope rather than trusting that stable ID.
        frontApp = "test.commandApp"
        let commandID = UUID()
        let originalCommand = VoiceRegisteredAction(action: mute.action, detail: "Original command",
            appBundleID: frontApp, appName: "Fixture", actionName: "Fixture command", customCommandID: commandID)
        let customDecision = VoiceDecision(matches: [VoiceMatch(record: originalCommand, probability: 1)], confidence: 1, noMatch: false)
        controller.prepareVoice = { voice, _ in voice.receive(customDecision, final: true) }
        func startCustom() {
            available = [originalCommand]
            controller.show(waitingForLift: false)
            controller.beginVoiceMode()
        }
        let executionsBefore = executed.count
        startCustom()
        var edited = VoiceRegisteredAction(action: pause.action, detail: "Edited output", appBundleID: frontApp,
            appName: "Fixture", actionName: "Fixture command", customCommandID: commandID)
        precondition(edited.id == originalCommand.id, "Command identity must survive output edits")
        available = [edited]
        controller.confirmVoiceAction()
        precondition(controller.displayedVoiceSession?.phase == .failed && executed.count == executionsBefore,
            "Stable-ID command edits must not execute a different output than the matched record")
        controller.dismiss()
        startCustom()
        edited = originalCommand; edited.enabled = false; available = [edited]
        controller.confirmVoiceAction()
        precondition(controller.displayedVoiceSession?.phase == .failed && executed.count == executionsBefore,
            "Disabled commands must fail closed even if still present in an injected catalog")
        controller.dismiss()
        startCustom()
        edited = originalCommand; edited.appBundleID = "test.otherApp"; available = [edited]
        precondition(edited.id == originalCommand.id)
        controller.confirmVoiceAction()
        precondition(controller.displayedVoiceSession?.phase == .failed && executed.count == executionsBefore,
            "Stable-ID command scope changes must fail closed")
        controller.dismiss()
        startCustom(); available = []
        controller.confirmVoiceAction()
        precondition(controller.displayedVoiceSession?.phase == .failed && executed.count == executionsBefore,
            "Removed custom commands must fail closed")
        controller.dismiss()
        startCustom(); frontApp = "test.otherApp"
        controller.confirmVoiceAction()
        precondition(controller.displayedVoiceSession?.phase == .failed && executed.count == executionsBefore,
            "Custom commands must fail closed after an application switch")
        controller.dismiss()
        frontApp = "test.commandApp"
        startCustom()
        controller.confirmVoiceAction()
        try await Task.sleep(nanoseconds: 80_000_000)
        precondition(executed.count == executionsBefore + 1 && executed.last == originalCommand.action,
            "An unchanged enabled custom command executes its originally matched output exactly once")

        // Render without recording or network access.

        let preview = VoiceSession()
        preview.makeCloud = { fake }; preview.makeMicrophone = { FakeMicrophone() }; preview.requestPermission = { true }
        preview.start(catalog: catalog)
        try await Task.sleep(nanoseconds: 30_000_000)
        preview.finishListening()
        try await Task.sleep(nanoseconds: 50_000_000)
        let host = NSHostingView(rootView: VoiceHUDView(session: preview, theme: .starburstAir, onExit: {}, onRetry: {}, onConfirm: {}))
        host.frame = NSRect(x: 0, y: 0, width: 470, height: 520)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        try await Task.sleep(nanoseconds: 100_000_000)
        host.layoutSubtreeIfNeeded()
        if let path = CommandLine.arguments.dropFirst().first,
           let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path).appendingPathComponent("voice-hud.png"))
        }
        preview.cancel(); window.close()
        print("Voice validation, transport-drain admission, final preemption/deadlines, provisional coalescing/dedup, monotonic endpoints, stale-result/catalog guards, credentials, swipe/confirm runtime, and HUD render: PASS")
    }
}
