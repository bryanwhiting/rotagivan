import AppKit
import AVFoundation
import Combine
import ApplicationServices

// This preference is local to this Mac, never a credential or synced setting.
enum LauncherVoiceProvider: String, CaseIterable, Identifiable {
    case openRouter, openAIRealtime
    var id: String { rawValue }
    var label: String { self == .openRouter ? "OpenRouter / Jev actions" : "OpenAI Realtime · live speech to text" }
    static let preferenceKey = "launcher.localVoiceProvider"
}

enum OpenAIRealtimeCredential {
    static func parse(_ text: String) -> String? { OpenRouterCredential.parse(text, variable: "OPENAI_ROTA_KEY") }
    static func load() async throws -> String {
        try await CredentialWorker.shared.run {
            if let key = try VaultKeychain.currentAPIKey(provider: .openAI) { return key }
            do { return try OpenRouterCredential.loadEnvironment(variable: "OPENAI_ROTA_KEY") }
            catch { throw VaultFailure.message("Add your OpenAI API key in General → Account & Sync → Encrypted API keys, then save or load your keys.") }
        }
    }
}

enum RealtimeStreamEvent: Equatable {
    case ready, transcript(String, final: Bool), failure(String)
}

/// Ordered by commit/item identity; completions replace partial text, never append
/// it twice. Duplicate event IDs and late deltas for completed turns are ignored.
struct RealtimeTranscriptAccumulator {
    private var order: [String] = []
    private var partial: [String: String] = [:]
    private var finals = Set<String>()
    private var eventIDs = Set<String>()
    mutating func accept(_ object: [String: Any]) -> RealtimeStreamEvent? {
        if let id = object["event_id"] as? String {
            guard eventIDs.insert(id).inserted else { return nil }
            guard eventIDs.count <= 4096 else { return .failure("Voice stream exceeded its event limit. Retry.") }
        }
        guard let type = object["type"] as? String else { return nil }
        if type == "session.updated" { return .ready }
        if type == "error" || type == "conversation.item.input_audio_transcription.failed" {
            // Provider messages can contain echoed requests; do not display/log them.
            return .failure("OpenAI voice request failed. Check the key, model access, and connection; retry explicitly.")
        }
        guard let item = object["item_id"] as? String else { return nil }
        if type == "input_audio_buffer.committed" {
            order.removeAll { $0 == item }
            if let previous = object["previous_item_id"] as? String, let i = order.firstIndex(of: previous) { order.insert(item, at: i + 1) }
                else if object["previous_item_id"] == nil || object["previous_item_id"] is NSNull { order.insert(item, at: 0) }
                else { order.append(item) }
            return nil
        }
        let final = type == "conversation.item.input_audio_transcription.completed"
        guard final || type == "conversation.item.input_audio_transcription.delta", !finals.contains(item) else { return nil }
        if !order.contains(item) { order.append(item) }
        guard order.count <= 64 else { return .failure("Voice stream exceeded its turn limit. Retry.") }
        if final {
            guard let text = object["transcript"] as? String else { return nil }
            partial[item] = String(text.prefix(1024)); finals.insert(item)
        } else if let delta = object["delta"] as? String {
            partial[item] = String(((partial[item] ?? "") + delta).prefix(1024))
        }
        let text = String(order.compactMap { partial[$0] }.joined(separator: " ").prefix(2048))
        return .transcript(text, final: final)
    }
}

@MainActor protocol RealtimeVoiceTransport: AnyObject {
    func start(onEvent: @escaping (RealtimeStreamEvent) -> Void) async throws
    func append(_ pcm: Data) async throws
    func commit() async throws
    func close()
}

@MainActor final class OpenAIRealtimeTransport: RealtimeVoiceTransport {
    static let model = "gpt-live-transcribe"
    static var sessionUpdate: [String: Any] {
        ["type": "session.update", "session": ["type": "transcription", "audio": ["input": [
            "format": ["type": "audio/pcm", "rate": 24000],
            "transcription": ["model": model, "delay": "low", "prompt": "Short macOS application names and menu commands."],
            "turn_detection": NSNull()]]]]
    }
    private var key: String
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var reader: Task<Void, Never>?
    private var generation = UUID()
    private var closed = false
    init(key: String) { self.key = key }
    private func send(_ object: [String: Any]) async throws {
        guard !closed, let socket else { throw CancellationError() }
        let data = try JSONSerialization.data(withJSONObject: object)
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }
    func start(onEvent: @escaping (RealtimeStreamEvent) -> Void) async throws {
        guard socket == nil, !closed else { throw CancellationError() }
        // Native URLSession transport; no key reaches a WebView/frontend or logs.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10; configuration.timeoutIntervalForResource = 30
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration); self.session = session
        var request = URLRequest(url: URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!)
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        key = ""
        let socket = session.webSocketTask(with: request); self.socket = socket
        socket.maximumMessageSize = 256 * 1024
        socket.resume()
        let token = generation
        reader = Task { [weak self] in
            var transcript = RealtimeTranscriptAccumulator()
            do {
                while !Task.isCancelled, let self, token == self.generation, !self.closed {
                    let message = try await socket.receive()
                    let data: Data
                    switch message { case .data(let d): data = d; case .string(let s): data = Data(s.utf8); @unknown default: continue }
                    guard token == self.generation, !self.closed,
                          let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                    if let event = transcript.accept(object) { onEvent(event) }
                }
            } catch {
                guard let self, token == self.generation, !self.closed, !Task.isCancelled else { return }
                onEvent(.failure("OpenAI disconnected or rejected authentication. Audio stopped; retry explicitly."))
            }
        }
        do { try await send(Self.sessionUpdate) } catch { close(); throw error }
    }
    func append(_ pcm: Data) async throws {
        guard pcm.count <= 96_000 else { throw VoiceError.message("Voice upload backlog exceeded its limit. Retry.") }
        try await send(["type": "input_audio_buffer.append", "audio": pcm.base64EncodedString()])
    }
    func commit() async throws { try await send(["type": "input_audio_buffer.commit"]) }
    func close() {
        guard !closed else { return }
        closed = true; generation = UUID(); key = ""
        reader?.cancel(); reader = nil
        socket?.cancel(with: .normalClosure, reason: nil); socket = nil
        session?.invalidateAndCancel(); session = nil
    }
}

@MainActor final class RealtimeLauncherSession: ObservableObject {
    enum Phase: Equatable { case preparing, listening, finishing, ready, failed, cancelled }
    @Published private(set) var phase: Phase = .preparing
    @Published private(set) var transcript = ""
    @Published private(set) var message = "Preparing OpenAI Realtime…"
    var onTranscript: ((String) -> Void)?
    var makeTransport: () async throws -> RealtimeVoiceTransport = { OpenAIRealtimeTransport(key: try await OpenAIRealtimeCredential.load()) }
    var makeMicrophone: () -> VoiceAudioCapturing = { VoiceMicrophone(sampleRate: 24000) }
    var requestPermission: () async -> Bool = {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }
    var admission = VoiceMicrophoneAdmission.shared
    var automaticTicks = true
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    private var generation = UUID()
    private var lease: UUID?
    private var cloudRegistration: UUID?
    private var awaitingPermission = false
    private var service: RealtimeVoiceTransport?
    private var microphone: VoiceAudioCapturing?
    private var preparation: Task<Void, Never>?
    private var upload: Task<Void, Never>?
    private var timer: Timer?
    private var sentBytes = 0
    private var audio = Data()
    private var started = 0.0
    private var deadline = 0.0
    private var committed = false
    func start() {
        cancel()
        guard lease == nil else { phase = .failed; message = "Microphone permission is still pending. Retry after it finishes."; return }
        let token = UUID(); generation = token
        guard admission.acquireCloud(token, cancel: { [weak self] in self?.cancel() }) else {
            phase = .failed; message = "Another microphone session or private note editor is active."; return
        }
        lease = token; cloudRegistration = token; phase = .preparing; transcript = ""; sentBytes = 0; audio = Data(); committed = false
        onTranscript?("")
        deadline = now() + 10; message = "Connecting to OpenAI Realtime…"
        if automaticTicks {
            let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
            self.timer = timer; RunLoop.main.add(timer, forMode: .common)
        }
        preparation = Task { [weak self] in
            guard let self else { return }
            do {
                let service = try await makeTransport()
                guard token == generation, !Task.isCancelled else { service.close(); return }
                self.service = service
                awaitingPermission = true
                let allowed = await requestPermission()
                awaitingPermission = false
                guard token == generation, !Task.isCancelled else { releaseLease(); return }
                guard allowed else { throw VoiceError.message("Microphone access is off. Enable it in macOS settings, then retry.") }
                try await service.start { [weak self] event in
                    guard let self, token == self.generation else { return }
                    self.receive(event)
                }
            } catch { if token == generation { fail("OpenAI voice setup failed. Check your OpenAI key in General → Account & Sync, microphone access, and connection; retry explicitly.") } }
        }
    }
    private func releaseLease() {
        guard !awaitingPermission, let lease else { return }
        admission.release(lease); self.lease = nil
    }
    private func receive(_ event: RealtimeStreamEvent) {
        switch event {
        case .ready:
            guard phase == .preparing else { return }
            do {
                let mic = makeMicrophone(); try mic.start(); microphone = mic
                started = now(); deadline = started + 12
                phase = .listening; message = "Listening · words update local search · Return chooses, never automatic"
            } catch { fail("Could not start the microphone. Check macOS Sound settings and retry.") }
        case .transcript(let text, let final):
            guard phase == .listening || phase == .finishing else { return }
            transcript = String(text.prefix(2048)); onTranscript?(transcript)
            if phase == .finishing, final {
                stopResources(); phase = .ready; message = "Finished · select a result and press Return"
            }
        case .failure(let message): fail(message)
        }
    }
    func tick() {
        if phase == .preparing || phase == .finishing {
            if now() >= deadline { fail("OpenAI voice timed out. Audio stopped; retry explicitly.") }
            return
        }
        guard phase == .listening, let mic = microphone else { return }
        let (pcm, speechAt, failed) = mic.buffer.snapshot()
        guard !failed else { fail("Microphone conversion failed. Audio stopped; retry."); return }
        audio = pcm
        if now() >= deadline || (speechAt != nil && now() - speechAt! > 0.85) { finish(); return }
        sendPending()
    }
    func finish() {
        guard phase == .listening, let mic = microphone else { return }
        mic.stop(); let (pcm, speechAt, failed) = mic.buffer.snapshot(); mic.buffer.clear(); microphone = nil
        releaseLease()
        guard !failed, speechAt != nil, pcm.count >= 4_800 else { fail("No usable speech heard. Retry."); return }
        audio = pcm; phase = .finishing; deadline = now() + 10
        message = "Finishing transcript… results remain available"
        sendPending()
    }
    private func sendPending() {
        guard upload == nil, let service, phase == .listening || phase == .finishing else { return }
        let token = generation
        upload = Task { [weak self] in
            guard let self else { return }
            defer { if token == generation { upload = nil } }
            do {
                while token == generation, !Task.isCancelled, sentBytes < audio.count {
                    let end = min(audio.count, sentBytes + 4_800)
                    let chunk = audio.subdata(in: sentBytes..<end)
                    try await service.append(chunk)
                    guard token == generation, !Task.isCancelled else { return }
                    sentBytes = end
                }
                guard token == generation, !Task.isCancelled else { return }
                if phase == .finishing, !committed {
                    committed = true; try await service.commit()
                }
            } catch { if token == generation { fail("Voice audio upload failed. Audio stopped; retry explicitly.") } }
        }
    }
    private func stopResources() {
        generation = UUID(); preparation?.cancel(); preparation = nil; upload?.cancel(); upload = nil
        microphone?.stop(); microphone?.buffer.clear(); microphone = nil
        service?.close(); service = nil; timer?.invalidate(); timer = nil
        audio = Data(); releaseLease()
        if let id = cloudRegistration { admission.endCloud(id); cloudRegistration = nil }
    }
    private func fail(_ message: String) { stopResources(); phase = .failed; self.message = message }
    func cancel() { stopResources(); phase = .cancelled; transcript = "" }
}
