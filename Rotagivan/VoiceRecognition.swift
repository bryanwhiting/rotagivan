import AppKit
import AVFoundation
import SwiftUI

@MainActor final class VoiceApplicationIndex: ObservableObject {
    static let shared = VoiceApplicationIndex()
    @Published private(set) var applications: [ExplorerApplication] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefreshedAt: Date?
    @Published private(set) var refreshError: String?
    private var loading: Task<Void, Never>?
    private var lastAttemptAt: Date?
    private let refreshInterval: TimeInterval
    private let scan: @Sendable () -> ExplorerApplicationCatalog.ScanResult

    init(refreshInterval: TimeInterval = 60,
         scan: @escaping @Sendable () -> ExplorerApplicationCatalog.ScanResult = { ExplorerApplicationCatalog.scanWithStatus() }) {
        self.refreshInterval = refreshInterval
        self.scan = scan
    }

    func load() async {
        // Listening can use the last complete snapshot while expired data refreshes.
        // First use still awaits a catalog, and explicit reindex always awaits completion.
        if lastRefreshedAt != nil {
            if loading == nil, lastAttemptAt.map({ Date().timeIntervalSince($0) >= refreshInterval }) ?? true {
                Task { await refresh() }
            }
            return
        }
        await refresh()
    }

    /// Only this machine's application roots are scanned; nothing is persisted or synced.
    /// Concurrent callers (including manual reindex) await the same background scan.
    func refresh(force: Bool = false) async {
        if let loading {
            await loading.value
            return
        }
        if !force, let lastAttemptAt, Date().timeIntervalSince(lastAttemptAt) < refreshInterval { return }
        isRefreshing = true
        refreshError = nil
        let scan = scan
        let work = Task { @MainActor in
            let result = await Task.detached(priority: .utility) { scan() }.value
            lastAttemptAt = Date()
            if result.errors.isEmpty {
                applications = result.applications
                lastRefreshedAt = lastAttemptAt
            } else {
                // Preserve the last complete catalog if a directory temporarily becomes unreadable.
                refreshError = result.errors.joined(separator: "\n")
            }
            isRefreshing = false
        }
        loading = work
        await work.value
        loading = nil
    }
}

/// A bounded in-memory PCM buffer; never writes microphone audio to disk.
final class VoiceAudioBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pcm = Data()
    private var speechAt: TimeInterval?
    private let now: @Sendable () -> TimeInterval
    private var failed = false
    private var levels = [Double](repeating: 0, count: 48)
    init(now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) { self.now = now }
    func waveform() -> [Double] {
        lock.lock(); defer { lock.unlock() }; return levels
    }
    static let maximumBytes = 16_000 * 2 * 12
    func append(_ data: Data, rms: Double) {
        lock.lock(); defer { lock.unlock() }
        pcm.append(data.prefix(max(0, Self.maximumBytes - pcm.count)))
        let level = rms.isFinite ? max(0, min(1, rms)) : 0
        levels.append(min(1, sqrt(level) * 2.5)); levels.removeFirst()
        if level > 0.008 { speechAt = now() }
    }
    func fail() { lock.lock(); failed = true; lock.unlock() }
    func snapshot() -> (Data, TimeInterval?, Bool) {
        lock.lock(); defer { lock.unlock() }
        return (pcm, speechAt, failed)
    }
    func clear() { lock.lock(); pcm.removeAll(); levels = Array(repeating: 0, count: 48); speechAt = nil; failed = false; lock.unlock() }
    static func wav(_ pcm: Data) -> Data {
        var result = Data()
        func text(_ value: String) { result.append(contentsOf: value.utf8) }
        func number<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { result.append(contentsOf: $0) }
        }
        text("RIFF"); number(UInt32(36 + pcm.count)); text("WAVEfmt ")
        number(UInt32(16)); number(UInt16(1)); number(UInt16(1))
        number(UInt32(16_000)); number(UInt32(32_000)); number(UInt16(2)); number(UInt16(16))
        text("data"); number(UInt32(pcm.count)); result.append(pcm)
        return result
    }
}

@MainActor protocol VoiceAudioCapturing: AnyObject {
    var buffer: VoiceAudioBuffer { get }
    func start() throws
    func stop()
}

@MainActor final class VoiceMicrophone: VoiceAudioCapturing {
    let buffer = VoiceAudioBuffer()
    private var engine: AVAudioEngine?
    func start() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: format, to: target) else {
            throw VoiceError.message("No usable microphone is available.")
        }
        let buffer = buffer
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { samples, _ in
            let capacity = AVAudioFrameCount(Double(samples.frameLength) * 16_000 / format.sampleRate) + 64
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { buffer.fail(); return }
            var supplied = false
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, state in
                if supplied { state.pointee = .noDataNow; return nil }
                supplied = true; state.pointee = .haveData; return samples
            }
            guard status != .error, error == nil, let floats = output.floatChannelData?[0] else { buffer.fail(); return }
            var pcm = Data(capacity: Int(output.frameLength) * 2)
            var energy = 0.0
            for index in 0..<Int(output.frameLength) {
                let sample = floats[index].isFinite ? max(-1, min(1, floats[index])) : 0
                energy += Double(sample * sample)
                var integer = Int16(sample * 32767).littleEndian
                withUnsafeBytes(of: &integer) { pcm.append(contentsOf: $0) }
            }
            buffer.append(pcm, rms: sqrt(energy / Double(max(1, output.frameLength))))
        }
        do { engine.prepare(); try engine.start(); self.engine = engine }
        catch { input.removeTap(onBus: 0); throw VoiceError.message("Could not start the microphone. Check macOS Sound settings.") }
    }
    func stop() {
        if let engine { engine.stop(); engine.inputNode.removeTap(onBus: 0) }
        engine = nil
    }
}

/// Shared across new controller sessions: UI cancellation never frees a
/// transport slot before its admitted work has actually returned.
@MainActor final class VoicePipelineAdmission {
    static let shared = VoicePipelineAdmission()
    private var owner: UUID?
    var occupied: Bool { owner != nil }
    func acquire(_ id: UUID) -> Bool {
        guard owner == nil else { return false }; owner = id; return true
    }
    func release(_ id: UUID) { if owner == id { owner = nil } }
}

@MainActor final class VoiceSession: ObservableObject {
    enum Phase: Equatable { case preparing, listening, matching, ready, failed, cancelled }
    @Published private(set) var phase: Phase = .preparing
    @Published private(set) var transcript = ""
    @Published private(set) var decision: VoiceDecision?
    @Published private(set) var message = "Preparing microphone…"
    @Published private(set) var waveform = [Double](repeating: 0, count: 48)
    var onFinalMatch: (() -> Void)?
    private var deliveredFinal = false
    @Published var selected: ExplorerSlot = .up
    private var microphone: VoiceAudioCapturing?
    var makeMicrophone: () -> VoiceAudioCapturing = { VoiceMicrophone() }
    private var timer: Timer?
    private var preparation: Task<Void, Never>?
    private var worker: Task<Void, Never>?
    private var operation: Task<Void, Never>?
    private var workerID: UUID?
    private var queued: (Data, Bool)?
    private var generation = UUID()
    private var started: TimeInterval = 0
    private var sentAt = -TimeInterval.infinity
    private var finalDeadline: TimeInterval?
    private var finalPending = false
    private var lastProvisionalTranscript: String?
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var automaticTicks = true
    var finalMatchingBudget: TimeInterval = 15
    var pipelineAdmission = VoicePipelineAdmission.shared
    /// The controller verifies its captured catalog/app scope at response
    /// boundaries, never in the waveform timer or during rendering.
    var isCatalogCurrent: ([VoiceRegisteredAction]) -> Bool = { _ in true }
    private var cloud: VoiceCloudServing?
    private var catalog: [VoiceRegisteredAction] = []
    var makeCloud: () async throws -> VoiceCloudServing = {
        let key = try await OpenRouterCredential.loadAsync()
        try Task.checkCancellation()
        return OpenRouterVoiceCloud(key: key)
    }
    var requestPermission: () async -> Bool = {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }
    var selectedMatch: VoiceMatch? {
        guard phase == .ready, let decision, !decision.noMatch,
              let index = [ExplorerSlot.up, .right, .down].firstIndex(of: selected),
              index < decision.matches.count else { return nil }
        return decision.matches[index]
    }
    func start(catalog: [VoiceRegisteredAction]) {
        cancel()
        guard worker == nil, !pipelineAdmission.occupied else {
            fail(VoiceError.message("Previous voice request is still stopping. Please retry when it finishes. Nothing was run.")); return
        }
        generation = UUID()
        let token = generation
        self.catalog = catalog
        deliveredFinal = false
        finalPending = false; finalDeadline = nil
        transcript = ""; decision = nil; selected = .up
        phase = .preparing; message = "Preparing voice credentials…"
        preparation = Task { [weak self] in
            guard let self else { return }
            do {
                let preparedCloud = try await self.makeCloud()
                guard token == self.generation, !Task.isCancelled else {
                    preparedCloud.close()
                    return
                }
                self.cloud = preparedCloud
                self.message = "Preparing microphone…"
                let allowed = await self.requestPermission()
                guard token == self.generation, !Task.isCancelled else { return }
                guard allowed else { throw VoiceError.message("Microphone access is off. Enable Rotagivan in System Settings → Privacy & Security → Microphone, then try again.") }
                let mic = self.makeMicrophone()
                try mic.start()
                self.microphone = mic
                self.started = self.now(); self.sentAt = -.infinity
                self.phase = .listening; self.message = "Listening… say an action · Space/Enter to finish"
                guard self.automaticTicks else { return }
                let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.tick() }
                }
                self.timer = timer
                RunLoop.main.add(timer, forMode: .common)
            } catch { if token == self.generation { self.fail(error) } }
        }
    }
    func tick() {
        if phase == .matching {
            checkMatchingDeadline()
            return
        }
        guard phase == .listening, let microphone else { return }
        waveform = microphone.buffer.waveform()
        let (pcm, speechAt, failed) = microphone.buffer.snapshot()
        if failed { fail(VoiceError.message("Microphone audio conversion failed. Please try again.")); return }
        let elapsed = now() - started
        if elapsed >= 12 || (speechAt != nil && now() - speechAt! > 0.85 && elapsed > 0.8) {
            finishListening(); return
        }
        if speechAt == nil && elapsed > 5 { fail(VoiceError.message("No speech heard. Tap Listen again to retry.")); return }
        if speechAt != nil && elapsed > 0.7 && now() - sentAt >= 1.2 {
            sentAt = now(); enqueue(VoiceAudioBuffer.wav(pcm), final: false)
        }
    }
    private func checkMatchingDeadline() {
        if phase == .matching, let deadline = finalDeadline, now() >= deadline {
            fail(VoiceError.message("Voice matching timed out. Tap Listen again to retry. Nothing was run."))
        }
    }
    func finishListening() {
        guard phase == .listening, let microphone else { return }
        microphone.stop()
        let (pcm, speechAt, failed) = microphone.buffer.snapshot()
        microphone.buffer.clear(); self.microphone = nil
        guard !failed, speechAt != nil, !pcm.isEmpty else { fail(VoiceError.message("No speech heard. Tap Listen again to retry.")); return }
        phase = .matching; message = "Matching your command…"
        finalPending = true
        finalDeadline = now() + max(0, finalMatchingBudget)
        // Priority starts with final audio, not after the final STT response.
        operation?.cancel(); cloud?.cancelRequests()
        enqueue(VoiceAudioBuffer.wav(pcm), final: true)
        tick()
    }
    private func enqueue(_ wav: Data, final: Bool) {
        queued = (wav, final) // Coalesce snapshots; at most one network pipeline.
        guard worker == nil else { return }
        let id = UUID()
        let admission = pipelineAdmission
        guard admission.acquire(id) else {
            fail(VoiceError.message("Previous voice request is still stopping. Please retry when it finishes. Nothing was run.")); return
        }
        let token = generation
        workerID = id
        worker = Task { [weak self] in
            guard let self else { admission.release(id); return }
            var finalResult: VoiceDecision?
            defer {
                admission.release(id)
                if self.workerID == id { self.worker = nil; self.workerID = nil; self.operation = nil }
                // Final callbacks may open a brand-new voice session. Only
                // publish after the actual operation has drained and released.
                if let finalResult, token == self.generation { self.receive(finalResult, final: true) }
            }
            while token == self.generation, let (audio, isFinal) = self.queued, let cloud = self.cloud {
                self.queued = nil
                var completedDecision: VoiceDecision?
                var completedTranscript: String?
                let operation = Task { @MainActor in
                  do {
                    let text = try await cloud.transcribe(audio)
                    guard token == self.generation, !Task.isCancelled else { return }
                    guard !self.finalPending || isFinal else { return }
                    self.checkMatchingDeadline()
                    guard token == self.generation, !Task.isCancelled, !self.finalPending || isFinal else { return }
                    guard self.isCatalogCurrent(self.catalog) else {
                        self.fail(VoiceError.message("The available actions or active application changed. Please try again. Nothing was run.")); return
                    }
                    if !text.isEmpty, self.transcript != text { self.transcript = text }
                    guard !text.isEmpty else {
                        if isFinal { throw VoiceError.message("No speech recognized. Tap Listen again to retry.") }
                        return
                    }
                    if !isFinal, self.lastProvisionalTranscript == text { return }
                    let decision = try await cloud.classify(text, catalog: self.catalog)
                    guard token == self.generation, !Task.isCancelled else { return }
                    guard !self.finalPending || isFinal else { return }
                    self.checkMatchingDeadline()
                    guard token == self.generation, !Task.isCancelled, !self.finalPending || isFinal else { return }
                    completedDecision = decision
                    completedTranscript = text
                  } catch {
                    guard token == self.generation, !Task.isCancelled else { return }
                    if isFinal { self.fail(error); return }
                    // A transient partial failure may recover on the final request.
                  }
                }
                self.operation = operation
                // Cancellation requests do not release admission: a transport
                // which ignores cancellation must drain before another starts.
                await operation.value
                if self.workerID == id { self.operation = nil }
                self.checkMatchingDeadline()
                guard token == self.generation else { return }
                if let decision = completedDecision {
                    guard self.isCatalogCurrent(self.catalog) else {
                        self.fail(VoiceError.message("The available actions or active application changed. Please try again. Nothing was run.")); return
                    }
                    if isFinal { finalResult = decision; return }
                    if !self.finalPending {
                        self.lastProvisionalTranscript = completedTranscript
                        self.receive(decision, final: false)
                    }
                }
            }
        }
    }
    func receive(_ decision: VoiceDecision, final: Bool) {
        guard phase != .cancelled && phase != .failed, !deliveredFinal else { return }
        guard final || (!finalPending && phase != .matching) else { return }
        self.decision = decision
        if final {
            deliveredFinal = true
            finalDeadline = nil; timer?.invalidate(); timer = nil
            phase = .ready
            selected = decision.noMatch ? .left : .up
            message = decision.noMatch ? "No matching action. Nothing will run." : "Swipe to select · Space or Enter to run"
            if !decision.noMatch, selectedMatch != nil { onFinalMatch?() }
        }
    }
    func select(_ direction: ExplorerSlot) {
        if [.up, .right, .down, .left].contains(direction) { selected = direction }
    }
    func fail(_ error: Error) {
        generation = UUID(); preparation?.cancel(); preparation = nil
        microphone?.stop(); microphone?.buffer.clear(); microphone = nil
        timer?.invalidate(); timer = nil
        operation?.cancel(); queued = nil; finalDeadline = nil; finalPending = false; lastProvisionalTranscript = nil
        cloud?.close(); cloud = nil
        waveform = Array(repeating: 0, count: 48)
        decision = nil; phase = .failed
        message = (error as? VoiceError)?.errorDescription ?? "Voice service unavailable. Check your connection and try again. Nothing was run."
    }
    func cancel() {
        generation = UUID()
        preparation?.cancel(); preparation = nil
        operation?.cancel(); queued = nil; finalDeadline = nil; finalPending = false; lastProvisionalTranscript = nil
        microphone?.stop(); microphone?.buffer.clear(); microphone = nil
        timer?.invalidate(); timer = nil
        cloud?.close(); cloud = nil
        waveform = Array(repeating: 0, count: 48)
        phase = .cancelled; decision = nil; transcript = ""; catalog = []
    }
}

/// A fixed four-sector layer: changing speech and status never moves the wheel.
struct VoiceHUDView: View {
    @ObservedObject var session: VoiceSession
    let theme: ExplorerTheme
    var onExit: () -> Void
    var onRetry: () -> Void
    var onConfirm: () -> Void
    var forceReduceTransparency = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private var opaque: Bool { forceReduceTransparency || reduceTransparency }
    private var centerTitle: String {
        switch session.phase {
        case .listening: return "Finish"
        case .ready: return session.selected == .left ? "Ignore" : "Run"
        case .failed, .cancelled: return "Retry"
        case .preparing, .matching: return "Wait"
        }
    }
    private var canConfirm: Bool {
        session.phase == .ready && (session.selected == .left || session.selectedMatch != nil)
    }
    private var centerEnabled: Bool {
        session.phase == .listening || session.phase == .failed || session.phase == .cancelled || canConfirm
    }
    private struct WheelState: Equatable {
        var phase: VoiceSession.Phase
        var selected: ExplorerSlot
        var theme: ExplorerTheme
        var opaque: Bool
        var matches: [String]
        var noMatch: Bool
    }
    private var wheelState: WheelState {
        WheelState(phase: session.phase, selected: session.selected, theme: theme, opaque: opaque,
            matches: session.decision?.matches.map { "\($0.id)|\($0.record.title)|\($0.probability)" } ?? [],
            noMatch: session.decision?.noMatch ?? true)
    }
    var body: some View {
        ZStack {
            ExplorerStableWheel(state: wheelState, content: wheel).equatable().offset(y: -10)
            VStack(spacing: 0) {
                header.frame(height: 72).background { floatingReadoutSurface }
                Spacer(minLength: 0)
                footer.frame(width: 418, height: 86).background { floatingReadoutSurface }
            }.padding(26)
        }
        .frame(width: 470, height: 520)
        .background(ExplorerHUDBackdrop(theme: theme, forceReduceTransparency: forceReduceTransparency))
        .tint(theme.accent)
        .environment(\.colorScheme, theme.isHUD ? .dark : colorScheme)
    }
    @ViewBuilder private var floatingReadoutSurface: some View {
        if theme.isFloating {
            RoundedRectangle(cornerRadius: 10).fill(theme.surface.opacity(0.96))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(theme.accent.opacity(0.2), lineWidth: 0.7))
                .allowsHitTesting(false).accessibilityHidden(true)
        }
    }
    private var header: some View {
        VStack(spacing: 5) {
            HStack {
                Label(session.phase == .listening ? "Listening" : "Voice mode",
                    systemImage: session.phase == .listening ? "mic.fill" : "waveform")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.accent)
                Spacer()
                Button(action: onExit) { Image(systemName: "xmark").font(.system(size: 11)) }
                    .buttonStyle(.plain).frame(width: 24, height: 24)
                    .accessibilityLabel("Cancel voice mode").accessibilityIdentifier("voice.cancel")
            }
            Text(session.transcript.isEmpty ? "Say an action, such as “open Slack”" : session.transcript)
                .font(.system(size: 12, weight: .medium)).multilineTextAlignment(.center)
                .lineLimit(2).frame(height: 30)
                .accessibilityLabel("Transcription: " + (session.transcript.isEmpty ? "No speech recognized yet" : session.transcript))
            HStack(spacing: 3) {
                ForEach(0..<48, id: \.self) { index in
                    Capsule().fill(theme.accent.opacity(session.phase == .listening ? 0.85 : 0.18))
                        .frame(width: 3, height: session.phase == .listening
                            ? max(2, min(14, (session.waveform.indices.contains(index) ? session.waveform[index] : 0) * 14)) : 2)
                }
            }.frame(height: 14).accessibilityElement(children: .ignore)
                .accessibilityLabel(session.phase == .listening ? "Microphone audio activity" : "Microphone idle")
        }
    }
    private var footer: some View {
        VStack(spacing: 2) {
            Text(session.phase == .cancelled ? "Voice cancelled. Nothing was run." : session.message)
                .font(.system(size: 11)).multilineTextAlignment(.center).lineLimit(4)
                .frame(height: 48).accessibilityIdentifier("voice.status")
            Text(session.decision.map {
                "Confidence \(Int(($0.confidence * 100).rounded()))% · \($0.shortlisted ? "Finalist scores" : "Action match scores")"
            } ?? "Select a match, then confirm · Esc to cancel")
                .font(.system(size: 9)).foregroundStyle(.secondary).frame(height: 12)
            Text("Audio → OpenRouter / xAI · Text + actions → Jev\nAudio and transcript are not saved by Rotagivan.")
                .font(.system(size: 8)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(height: 22)
        }
    }
    private var wheel: some View {
        let center = CGPoint(x: 209, y: 155)
        return ZStack {
            if theme.isFloating {
                ExplorerAirGlass(opaque: opaque).frame(width: 304, height: 304).position(center)
            }
            ForEach([ExplorerSlot.up, .right, .down, .left], id: \.self) { option($0) }
            Button {
                switch session.phase {
                case .listening: session.finishListening()
                case .ready: if canConfirm { onConfirm() }
                case .failed, .cancelled: onRetry()
                case .preparing, .matching: break
                }
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: session.phase == .listening ? "stop.fill" :
                        session.phase == .ready ? (session.selected == .left ? "xmark" : "return") : "mic.fill")
                        .font(.system(size: 13, weight: .medium))
                    Text(centerTitle).font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(theme.accent).frame(width: 54, height: 54)
                .background(Circle().fill(theme.isHUD ? theme.surface.opacity(theme.isFloating && !opaque ? 0.88 : 1) : Color(nsColor: .windowBackgroundColor)))
                .overlay(Circle().strokeBorder(theme.accent.opacity(0.65), lineWidth: 1))
                .contentShape(Circle())
            }.buttonStyle(.plain).disabled(!centerEnabled).position(center)
                .accessibilityLabel(centerTitle == "Run" ? "Run selected action" : centerTitle == "Ignore" ? "Ignore command" : centerTitle == "Finish" ? "Finish listening" : centerTitle == "Retry" ? "Listen again" : "Processing voice command")
                .accessibilityIdentifier("voice.confirm")
        }.frame(width: 418, height: 310)
    }
    private func option(_ direction: ExplorerSlot) -> some View {
        let index = [ExplorerSlot.up, .right, .down].firstIndex(of: direction)
        let match = index.flatMap { i in session.decision.flatMap { i < $0.matches.count && !$0.noMatch ? $0.matches[i] : nil } }
        let available = direction == .left || (session.phase == .ready && match != nil)
        let selected = session.selected == direction && available
        let shape = ExplorerStarburstSector(direction: direction,
            innerRadius: ExplorerStarburstLayout.innerRadius(depth: 0), outerRadius: 143,
            tip: theme.isFloating ? 2 : 11, halfAngle: 43, roundedRim: theme.isFloating)
        let point = ExplorerStarburstLayout.point(direction, radius: 108, center: CGPoint(x: 209, y: 155))
        let title = direction == .left ? "Cancel / Ignore" : (match?.record.title ?? "No match")
        return Button {
            // Cancelling an in-flight recording is always available; ready results
            // select Ignore and still require confirmation.
            if direction == .left && session.phase != .ready { onExit() }
            else { session.select(direction) }
        } label: {
            ZStack {
                ExplorerSectorChrome(theme: theme, shape: shape, selected: selected, available: available, opaque: opaque)
                VStack(spacing: 3) {
                    Image(systemName: direction == .left ? "xmark" : "bolt.fill")
                        .font(.system(size: 16, weight: .light)).foregroundStyle(theme.accent)
                    Text(title).font(.system(size: 10, weight: .medium))
                        .lineLimit(3).multilineTextAlignment(.center)
                    Text(match.map { "\(Int(($0.probability * 100).rounded()))% match" }
                        ?? (direction == .left ? "Nothing will run" : ["Best match", "Second match", "Third match"][index ?? 0]))
                        .font(.system(size: 8)).foregroundStyle(theme.accent)
                }.frame(width: 84, height: 72).position(point)
                    .foregroundStyle(theme.isHUD ? Color.white.opacity(available ? 0.9 : 0.45) : Color.primary)
            }.frame(width: 418, height: 310).contentShape(shape)
        }.buttonStyle(.plain).disabled(!available)
            .modifier(ExplorerSectorFocus(theme: theme, shape: shape))
            .accessibilityLabel("\(direction.title): \(title)" + (match.map { ", \(Int(($0.probability * 100).rounded())) percent match" } ?? ""))
            .accessibilityIdentifier("voice.tile.\(direction.rawValue)")
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
