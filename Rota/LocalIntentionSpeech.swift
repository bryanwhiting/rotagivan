import Foundation
import Combine
import Speech
import AVFoundation

@MainActor protocol LocalIntentionSpeechBackend: AnyObject {
    var supportsOnDeviceRecognition: Bool { get }
    func requestPermissions() async throws -> Bool
    func start(onTranscript: @escaping @MainActor (String, Bool) -> Void,
               onError: @escaping @MainActor () -> Void) throws
    /// Stops capture synchronously; recognition may briefly finalize locally.
    func stop()
    func cancel()
    /// One line set by `start()` when the chosen microphone could not be used
    /// and capture fell back to the system default; `nil` otherwise.
    var inputDeviceNotice: String? { get }
}
extension LocalIntentionSpeechBackend {
    var inputDeviceNotice: String? { nil }
}

/// Shared by the actual native backend and offline request-contract tests.
enum LocalIntentionSpeechPrivacy {
    static func request() -> SFSpeechAudioBufferRecognitionRequest {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = false
        return request
    }
}

@MainActor private final class NativeLocalIntentionSpeechBackend: LocalIntentionSpeechBackend {
    private lazy var recognizer = SFSpeechRecognizer(locale: Locale.current)
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognition: SFSpeechRecognitionTask?
    private var hasTap = false
    private var generation = UUID()
    private(set) var inputDeviceNotice: String?
    var supportsOnDeviceRecognition: Bool { recognizer?.supportsOnDeviceRecognition == true }

    func requestPermissions() async throws -> Bool {
        guard supportsOnDeviceRecognition else { return false }
        let speech: SFSpeechRecognizerAuthorizationStatus
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            speech = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
        } else { speech = SFSpeechRecognizer.authorizationStatus() }
        try Task.checkCancellation()
        guard speech == .authorized else { return false }
        let microphone: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: microphone = true
        case .notDetermined: microphone = await AVCaptureDevice.requestAccess(for: .audio)
        default: microphone = false
        }
        try Task.checkCancellation()
        return microphone
    }

    func start(onTranscript: @escaping @MainActor (String, Bool) -> Void,
               onError: @escaping @MainActor () -> Void) throws {
        cancel()
        // Both guards are mandatory: there is no server-recognition fallback.
        guard let recognizer, recognizer.supportsOnDeviceRecognition, recognizer.isAvailable else {
            throw LocalIntentionSpeechFailure.unavailable
        }
        let request = LocalIntentionSpeechPrivacy.request()
        self.request = request
        let token = generation
        recognition = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal == true
            let failed = error != nil
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                if let text { onTranscript(text, final) }
                if failed && !final { onError() }
            }
        }
        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        // The input format depends on the device, so select it first.
        inputDeviceNotice = VoiceInputDevices.apply(to: engine)
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            cancel(); throw LocalIntentionSpeechFailure.unavailable
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
        hasTap = true
        engine.prepare()
        do { try engine.start() }
        catch { cancel(); throw error }
    }
    func stop() {
        if let engine {
            engine.stop()
            if hasTap { engine.inputNode.removeTap(onBus: 0) }
        }
        hasTap = false
        engine = nil
        request?.endAudio()
    }
    func cancel() {
        generation = UUID()
        stop(); recognition?.cancel(); recognition = nil; request = nil
    }
}

private enum LocalIntentionSpeechFailure: Error { case unavailable }

/// Private dictation only populates editable text. It never saves an intention,
/// sends a request, or falls back to network recognition.
@MainActor final class LocalIntentionSpeech: ObservableObject {
    enum Phase: Equatable { case idle, preparing, listening, stopping, finished, failed, cancelled }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var transcript = ""
    @Published private(set) var message = "Dictation stays on this Mac."
    private let backend: LocalIntentionSpeechBackend
    private let admission: VoiceMicrophoneAdmission
    private let sleep: @MainActor (Duration) async throws -> Void
    private var generation = UUID()
    private var lease: UUID?
    private var preparingToken: UUID?
    private var preparation: Task<Void, Never>?
    private var timer: Task<Void, Never>?

    init(backend: LocalIntentionSpeechBackend? = nil,
         admission: VoiceMicrophoneAdmission? = nil,
         sleep: @escaping @MainActor (Duration) async throws -> Void = { try await ContinuousClock().sleep(for: $0) }) {
        self.backend = backend ?? NativeLocalIntentionSpeechBackend()
        self.admission = admission ?? .shared; self.sleep = sleep
    }

    func start() {
        guard lease == nil, phase != .stopping else {
            message = "Previous microphone preparation is still stopping. Please retry."; return
        }
        guard backend.supportsOnDeviceRecognition else {
            phase = .failed; message = "On-device dictation is unavailable for this Mac's language. Type the intention instead."; return
        }
        let token = UUID()
        guard admission.acquirePrivate(token) else {
            phase = .failed; message = "Voice mode is still stopping. Please retry or type the intention."; return
        }
        generation = token; lease = token; preparingToken = token
        transcript = ""; phase = .preparing; message = "Preparing private dictation…"
        arm(.seconds(30), token: token) { $0.fail("Dictation permission preparation timed out. Type the intention or retry.") }
        preparation = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.preparingToken == token {
                    self.preparingToken = nil; self.preparation = nil
                    if self.generation != token { self.release(token) }
                }
            }
            do {
                let allowed = try await self.backend.requestPermissions()
                guard self.generation == token, !Task.isCancelled else { return }
                guard allowed else {
                    self.fail("Speech Recognition and Microphone permission are required for private dictation. Type instead or enable them in System Settings."); return
                }
                guard self.backend.supportsOnDeviceRecognition else {
                    self.fail("On-device recognition is unavailable. Type the intention instead."); return
                }
                try self.backend.start(onTranscript: { [weak self] text, final in
                    guard let self, self.generation == token,
                          self.phase == .listening || self.phase == .stopping else { return }
                    let tooLong = text.count > TemporaryIntentionStore.maximumCharacters
                    self.transcript = String(text.prefix(TemporaryIntentionStore.maximumCharacters + 1))
                    if final { self.finish() }
                    else if tooLong { self.stop() }
                    if tooLong { self.message = "Dictation reached the 500-character limit. Shorten the text before setting the intention." }
                }, onError: { [weak self] in
                    guard let self, self.generation == token else { return }
                    self.fail("On-device dictation could not finish. Edit the text or try again.")
                })
                guard self.generation == token, !Task.isCancelled else { self.backend.cancel(); return }
                self.phase = .listening
                self.message = (self.backend.inputDeviceNotice.map { "\($0) " } ?? "") + "Listening privately… Stop when finished."
                self.arm(.seconds(30), token: token) { $0.stop() }
            } catch {
                guard self.generation == token, !Task.isCancelled else { return }
                self.fail("Private dictation could not start. Type the intention or try again.")
            }
        }
    }

    func stop() {
        guard phase == .listening else { if phase == .preparing { cancel() }; return }
        backend.stop(); if let lease { release(lease) }
        phase = .stopping; message = "Finishing on this Mac…"
        arm(.seconds(3), token: generation) { $0.finish() }
    }
    func cancel() {
        terminate(.cancelled, message: "Private dictation cancelled.")
        transcript = ""
    }
    private func finish() { terminate(.finished, message: "Edit the text, then choose Set intention.") }
    private func fail(_ message: String) { terminate(.failed, message: message) }
    private func terminate(_ phase: Phase, message: String) {
        generation = UUID(); timer?.cancel(); timer = nil
        preparation?.cancel(); backend.cancel()
        // A late permission response still owns admission until it returns.
        if preparingToken == nil, let lease { release(lease) }
        self.phase = phase; self.message = message
    }
    private func release(_ token: UUID) {
        admission.release(token)
        if lease == token { lease = nil }
    }
    private func arm(_ duration: Duration, token: UUID, action: @escaping @MainActor (LocalIntentionSpeech) -> Void) {
        timer?.cancel()
        let sleep = sleep
        timer = Task { @MainActor [weak self] in
            do { try await sleep(duration) } catch { return }
            guard !Task.isCancelled, let self, self.generation == token else { return }
            action(self)
        }
    }
    deinit {
        timer?.cancel(); preparation?.cancel()
        let backend = backend, admission = admission, lease = lease
        Task { @MainActor in
            backend.cancel()
            if let lease { admission.release(lease) }
        }
    }
}
