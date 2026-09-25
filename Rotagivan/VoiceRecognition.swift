import AppKit
import AVFoundation
import SwiftUI

@MainActor final class VoiceApplicationIndex: ObservableObject {
    static let shared = VoiceApplicationIndex()
    @Published private(set) var applications: [ExplorerApplication] = []
    private var loading: Task<[ExplorerApplication], Never>?
    private var loaded = false
    func load() async {
        if loaded { return }
        let work: Task<[ExplorerApplication], Never>
        if let loading { work = loading }
        else {
            work = Task.detached(priority: .utility) { ExplorerApplicationCatalog.scan() }
            loading = work
        }
        applications = await work.value
        loaded = true
        loading = nil
    }
}

/// A bounded in-memory PCM buffer; never writes microphone audio to disk.
final class VoiceAudioBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pcm = Data()
    private var speechAt: Date?
    private var failed = false
    private var levels = [Double](repeating: 0, count: 48)
    func waveform() -> [Double] {
        lock.lock(); defer { lock.unlock() }; return levels
    }
    static let maximumBytes = 16_000 * 2 * 12
    func append(_ data: Data, rms: Double) {
        lock.lock(); defer { lock.unlock() }
        pcm.append(data.prefix(max(0, Self.maximumBytes - pcm.count)))
        let level = rms.isFinite ? max(0, min(1, rms)) : 0
        levels.append(min(1, sqrt(level) * 2.5)); levels.removeFirst()
        if level > 0.008 { speechAt = Date() }
    }
    func fail() { lock.lock(); failed = true; lock.unlock() }
    func snapshot() -> (Data, Date?, Bool) {
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
    private var queued: (Data, Bool)?
    private var generation = UUID()
    private var started = Date()
    private var sentAt = Date.distantPast
    private var cloud: VoiceCloudServing?
    private var catalog: [VoiceRegisteredAction] = []
    var makeCloud: () throws -> VoiceCloudServing = { OpenRouterVoiceCloud(key: try OpenRouterCredential.load()) }
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
        generation = UUID()
        let token = generation
        self.catalog = catalog
        deliveredFinal = false
        transcript = ""; decision = nil; selected = .up
        phase = .preparing; message = "Preparing microphone…"
        preparation = Task { [weak self] in
            guard let self else { return }
            do {
                self.cloud = try self.makeCloud()
                let allowed = await self.requestPermission()
                guard token == self.generation, !Task.isCancelled else { return }
                guard allowed else { throw VoiceError.message("Microphone access is off. Enable Rotagivan in System Settings → Privacy & Security → Microphone, then try again.") }
                let mic = self.makeMicrophone()
                try mic.start()
                self.microphone = mic
                self.started = Date(); self.sentAt = .distantPast
                self.phase = .listening; self.message = "Listening… say an action · Space/Enter to finish"
                let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.tick() }
                }
                self.timer = timer
                RunLoop.main.add(timer, forMode: .common)
            } catch { if token == self.generation { self.fail(error) } }
        }
    }
    private func tick() {
        guard phase == .listening, let microphone else { return }
        waveform = microphone.buffer.waveform()
        let (pcm, speechAt, failed) = microphone.buffer.snapshot()
        if failed { fail(VoiceError.message("Microphone audio conversion failed. Please try again.")); return }
        let elapsed = Date().timeIntervalSince(started)
        if elapsed >= 12 || (speechAt != nil && Date().timeIntervalSince(speechAt!) > 0.85 && elapsed > 0.8) {
            finishListening(); return
        }
        if speechAt == nil && elapsed > 5 { fail(VoiceError.message("No speech heard. Tap Listen again to retry.")); return }
        if speechAt != nil && elapsed > 0.7 && Date().timeIntervalSince(sentAt) >= 1.2 {
            sentAt = Date(); enqueue(VoiceAudioBuffer.wav(pcm), final: false)
        }
    }
    func finishListening() {
        guard phase == .listening, let microphone else { return }
        microphone.stop(); timer?.invalidate(); timer = nil
        let (pcm, speechAt, failed) = microphone.buffer.snapshot()
        microphone.buffer.clear(); self.microphone = nil
        guard !failed, speechAt != nil, !pcm.isEmpty else { fail(VoiceError.message("No speech heard. Tap Listen again to retry.")); return }
        phase = .matching; message = "Matching your command…"
        enqueue(VoiceAudioBuffer.wav(pcm), final: true)
    }
    private func enqueue(_ wav: Data, final: Bool) {
        queued = (wav, final) // Coalesce snapshots; at most one network pipeline.
        guard worker == nil else { return }
        let token = generation
        worker = Task { [weak self] in
            guard let self else { return }
            while let (audio, isFinal) = self.queued, let cloud = self.cloud {
                self.queued = nil
                do {
                    let text = try await cloud.transcribe(audio)
                    guard token == self.generation, !Task.isCancelled else { return }
                    if !text.isEmpty { self.transcript = text }
                    // A final upload supersedes an in-flight partial transcript.
                    if !isFinal && self.queued?.1 == true { continue }
                    guard !text.isEmpty else {
                        if isFinal { throw VoiceError.message("No speech recognized. Tap Listen again to retry.") }
                        continue
                    }
                    let decision = try await cloud.classify(text, catalog: self.catalog)
                    guard token == self.generation, !Task.isCancelled else { return }
                    if !isFinal && self.queued?.1 == true { continue }
                    self.receive(decision, final: isFinal)
                } catch {
                    guard token == self.generation, !Task.isCancelled else { return }
                    if isFinal { self.fail(error); return }
                    // A transient partial failure may recover on the final request.
                }
            }
            if token == self.generation { self.worker = nil }
        }
    }
    func receive(_ decision: VoiceDecision, final: Bool) {
        guard phase != .cancelled && phase != .failed else { return }
        self.decision = decision
        if final {
            guard !deliveredFinal else { return }
            deliveredFinal = true
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
        microphone?.stop(); microphone?.buffer.clear(); microphone = nil
        timer?.invalidate(); timer = nil
        worker?.cancel(); worker = nil; queued = nil
        (cloud as? OpenRouterVoiceCloud)?.close(); cloud = nil
        waveform = Array(repeating: 0, count: 48)
        decision = nil; phase = .failed
        message = (error as? VoiceError)?.errorDescription ?? "Voice service unavailable. Check your connection and try again. Nothing was run."
    }
    func cancel() {
        generation = UUID()
        preparation?.cancel(); preparation = nil
        worker?.cancel(); worker = nil; queued = nil
        microphone?.stop(); microphone?.buffer.clear(); microphone = nil
        timer?.invalidate(); timer = nil
        (cloud as? OpenRouterVoiceCloud)?.close(); cloud = nil
        waveform = Array(repeating: 0, count: 48)
        phase = .cancelled; decision = nil; transcript = ""; catalog = []
    }
}

struct VoiceHUDView: View {
    @ObservedObject var session: VoiceSession
    var onExit: () -> Void
    var onRetry: () -> Void
    var onConfirm: () -> Void
    private let cyan = Color(red: 0.2, green: 0.88, blue: 0.95)
    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Label(session.phase == .listening ? "Listening" : "Voice actions", systemImage: session.phase == .listening ? "mic.fill" : "waveform")
                    .foregroundStyle(cyan).font(.headline)
                Spacer()
                Button(action: onExit) { Image(systemName: "xmark") }.help("Exit voice mode")
            }
            Text(session.transcript.isEmpty ? "Say “Slack” or “open Slack”" : session.transcript)
                .font(.system(size: 21, weight: .medium)).multilineTextAlignment(.center)
                .lineLimit(3).frame(height: 78)
                .accessibilityLabel("Transcription: " + session.transcript)
            waveformView
            radialView
            Text(session.message).font(.callout).multilineTextAlignment(.center).frame(minHeight: 38)
            if let decision = session.decision {
                Text("Jev confidence \(Int((decision.confidence * 100).rounded()))% · \(decision.shortlisted ? "Scores among finalists" : "Action match scores")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button(session.selected == .left ? "Ignore command" : "Run selected action") { onConfirm() }
                .disabled(session.selected != .left && session.selectedMatch == nil)
            Text("Audio → OpenRouter / xAI · Text + action descriptions → Jev\nAudio and transcript are not saved by Rotagivan.")
                .font(.system(size: 10)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(24).frame(width: 530)
        .background(RoundedRectangle(cornerRadius: 26).fill(Color(red: 0.035, green: 0.08, blue: 0.10).opacity(0.98)))
        .overlay(RoundedRectangle(cornerRadius: 26).stroke(cyan.opacity(0.45), lineWidth: 1))
        .environment(\.colorScheme, .dark).tint(cyan)
    }
    @ViewBuilder private var waveformView: some View {
            if session.phase == .listening || session.phase == .preparing {
                HStack(spacing: 3) {
                    ForEach(0..<48, id: \.self) { index in
                        Capsule().fill(cyan.opacity(0.85))
                            .frame(width: 4, height: max(3, session.waveform[index] * 56))
                    }
                }.frame(height: 60)
                    .accessibilityLabel("Microphone audio level")
            }
    }
    private var radialView: some View {
            ZStack {
                Circle().fill(Color.white.opacity(0.025))
                    .overlay(Circle().stroke(cyan.opacity(0.3), lineWidth: 1))
                option(.up, index: 0)
                option(.right, index: 1)
                option(.down, index: 2)
                option(.left, index: nil)
                Button {
                    if session.phase == .listening { session.finishListening() }
                    else if session.phase == .ready { onConfirm() }
                    else if session.phase == .failed { onRetry() }
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: session.phase == .listening ? "stop.fill" : session.phase == .ready ? "return" : "mic.fill")
                        Text(session.phase == .listening ? "Finish" : session.phase == .ready ? "Run" : session.phase == .failed ? "Retry" : "Wait")
                            .font(.system(size: 10, weight: .medium))
                    }.frame(width: 82, height: 82)
                        .background(Circle().fill(Color.black.opacity(0.35)))
                        .overlay(Circle().stroke(cyan.opacity(0.65), lineWidth: 1))
                }.buttonStyle(.plain).foregroundStyle(cyan)
                    .disabled(session.phase == .matching || session.phase == .preparing)
            }.frame(width: 350, height: 350)
    }
    private func option(_ direction: ExplorerSlot, index: Int?) -> some View {
        let match = index.flatMap { i in session.decision.flatMap { i < $0.matches.count ? $0.matches[i] : nil } }
        let active = session.selected == direction
        let sector = ExplorerStarburstSector(direction: direction, innerRadius: 48, outerRadius: 170, halfAngle: 43, roundedRim: true)
        let angle = ExplorerStarburstLayout.angle(direction) * .pi / 180
        return Button { session.select(direction) } label: {
            ZStack {
                sector.fill(active ? cyan.opacity(0.2) : Color.white.opacity(0.04))
                sector.stroke(active ? cyan : cyan.opacity(0.25), lineWidth: active ? 2 : 1)
                VStack(spacing: 5) {
                    Text(direction == .left ? "Exit / Ignore" : (match?.record.title ?? "—"))
                        .font(.system(size: 12, weight: .semibold)).lineLimit(3)
                    if let match {
                        Text("\(Int((match.probability * 100).rounded()))% match").font(.caption).foregroundStyle(cyan)
                    } else if direction == .left {
                        Text("Nothing will run").font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }.multilineTextAlignment(.center).frame(width: 102, height: 78)
                    .offset(x: cos(angle) * 111, y: sin(angle) * 111)
            }.frame(width: 350, height: 350).contentShape(sector)
        }.buttonStyle(.plain).accessibilityLabel(direction == .left ? "Exit or ignore" : "\(match?.record.title ?? "No match"), \(Int(((match?.probability ?? 0) * 100).rounded())) percent match")

    }
}
