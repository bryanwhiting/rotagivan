import Foundation
import Combine
import AVFoundation

/// Explicit note dictation only. Audio goes to STT; note text never enters
/// action matching, and this service never commits a note automatically.
@MainActor final class NoteDictationSession: ObservableObject {
    enum Phase: Equatable { case idle, preparing, listening, stopping, finished, failed, cancelled }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var transcript = ""
    @Published private(set) var message = "Dictate a note or type it."
    private let microphone: VoiceAudioCapturing
    private let admission: VoiceMicrophoneAdmission
    private let pipeline: VoicePipelineAdmission
    private let makeCloud: () async throws -> VoiceCloudServing
    private let permission: () async -> Bool
    private let sleep: @MainActor (Duration) async throws -> Void
    private let now: () -> ContinuousClock.Instant
    private var generation = UUID()
    private var lease: UUID?
    private var preparing = false
    private var worker: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var cloud: VoiceCloudServing?

    init(microphone: VoiceAudioCapturing? = nil,
         admission: VoiceMicrophoneAdmission? = nil,
         pipelineAdmission: VoicePipelineAdmission? = nil,
         makeCloud: (() async throws -> VoiceCloudServing)? = nil,
         requestPermission: (() async -> Bool)? = nil,
         sleep: @escaping @MainActor (Duration) async throws -> Void = { try await ContinuousClock().sleep(for: $0) },
         now: @escaping () -> ContinuousClock.Instant = { ContinuousClock().now }) {
        self.microphone = microphone ?? VoiceMicrophone()
        self.admission = admission ?? .shared; pipeline = pipelineAdmission ?? .shared
        self.makeCloud = makeCloud ?? {
            let key = try await OpenRouterCredential.loadAsync()
            try Task.checkCancellation()
            return OpenRouterVoiceCloud(key: key)
        }
        permission = requestPermission ?? {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return true
            case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
            default: return false
            }
        }
        self.sleep = sleep; self.now = now
    }

    func start() {
        guard worker == nil, lease == nil else { message = "Previous dictation is still stopping. Please retry."; return }
        let token = UUID()
        guard !pipeline.occupied, admission.acquirePrivate(token) else {
            phase = .failed; message = "Voice is still stopping. Please retry or type the note."; return
        }
        generation = token; lease = token; preparing = true
        microphone.buffer.clear(); transcript = ""
        phase = .preparing; message = "Preparing note dictation…"
        let preparationDeadline = now().advanced(by: .seconds(15))
        arm(.seconds(15), token: token) { $0.fail("Dictation preparation timed out. Type the note or retry.") }
        worker = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.preparing = false; self.worker = nil
                if self.generation != token { self.releaseMicrophone(token) }
            }
            do {
                let prepared = try await self.makeCloud()
                guard self.generation == token, !Task.isCancelled else { prepared.close(); return }
                guard self.now() < preparationDeadline else {
                    prepared.close(); self.fail("Dictation preparation timed out. Type the note or retry."); return
                }
                self.cloud = prepared
                let allowed = await self.permission()
                guard self.generation == token, !Task.isCancelled else { return }
                guard self.now() < preparationDeadline else {
                    self.fail("Dictation preparation timed out. Type the note or retry."); return
                }
                guard allowed else { self.fail("Microphone access is required. Enable it in System Settings or type the note."); return }
                try self.microphone.start()
                guard self.generation == token, !Task.isCancelled else { self.microphone.stop(); return }
                self.phase = .listening; self.message = "Recording note audio — up to 12 seconds."
                self.arm(.seconds(12), token: token) { $0.stop() }
            } catch {
                guard self.generation == token, !Task.isCancelled else { return }
                self.fail("Could not prepare note dictation. Check your OpenRouter key or type the note.")
            }
        }
    }

    func stop() {
        guard phase == .listening else { if phase == .preparing { cancel() }; return }
        let token = generation
        microphone.stop(); releaseMicrophone(token)
        let (pcm, _, failed) = microphone.buffer.snapshot()
        microphone.buffer.clear()
        guard !failed, !pcm.isEmpty, let cloud else { fail("No usable audio was recorded. Try again or type the note."); return }
        guard pipeline.acquire(token) else { fail("Voice transcription is still stopping. Please retry."); return }
        let deadline = now().advanced(by: .seconds(15))
        phase = .stopping; message = "Transcribing note audio with OpenRouter…"
        arm(.seconds(15), token: token) { $0.fail("Note transcription timed out. Type the note or retry after it stops.") }
        let pipeline = pipeline
        worker = Task { @MainActor [weak self] in
            defer { pipeline.release(token) }
            guard let self else { cloud.close(); return }
            defer { self.worker = nil }
            do {
                let text = try await cloud.transcribe(VoiceAudioBuffer.wav(pcm))
                guard self.generation == token, !Task.isCancelled else { return }
                guard self.now() < deadline else { self.fail("Note transcription timed out. Type the note or retry."); return }
                self.transcript = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(501))
                self.timer?.cancel(); self.timer = nil; cloud.close(); self.cloud = nil
                self.phase = .finished
                self.message = self.transcript.count > 500 ? "The note exceeds 500 characters. Shorten it before saving." : "Edit the text, then choose Save note."
            } catch {
                guard self.generation == token, !Task.isCancelled else { return }
                self.fail("Note transcription failed. Try again or type the note.")
            }
        }
    }

    func cancel() { terminate(.cancelled, "Note dictation cancelled."); transcript = "" }
    private func fail(_ text: String) { terminate(.failed, text) }
    private func terminate(_ phase: Phase, _ text: String) {
        generation = UUID(); timer?.cancel(); timer = nil
        worker?.cancel(); cloud?.close(); cloud = nil
        microphone.stop(); microphone.buffer.clear()
        if !preparing, let lease { releaseMicrophone(lease) }
        self.phase = phase; message = text
        // Actual awaited transport/permission completion releases admission.
    }
    private func releaseMicrophone(_ token: UUID) {
        admission.release(token); if lease == token { lease = nil }
    }
    private func arm(_ duration: Duration, token: UUID, action: @escaping @MainActor (NoteDictationSession) -> Void) {
        timer?.cancel(); let sleep = sleep
        timer = Task { @MainActor [weak self] in
            do { try await sleep(duration) } catch { return }
            guard !Task.isCancelled, let self, self.generation == token else { return }
            action(self)
        }
    }
    deinit {
        worker?.cancel(); timer?.cancel()
        let microphone = microphone, admission = admission, lease = lease, cloud = cloud
        Task { @MainActor in
            cloud?.close(); microphone.stop(); microphone.buffer.clear()
            if let lease { admission.release(lease) }
        }
    }
}
