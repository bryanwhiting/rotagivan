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

        let controller = AppExplorerController(defaults: defaults)
        controller.configuration = { AppExplorerSettings() }
        controller.frontmostPID = { 4242 }; controller.frontmostBundleID = { "com.apple.finder" }
        controller.contextIsValid = { true }
        var available = catalog
        controller.voiceCatalog = { available }
        controller.prepareVoice = { voice, _ in voice.receive(decision, final: true) }
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
        controller.process(report(false))
        precondition(controller.displayedVoiceSession?.selected == .right)
        precondition(executed.isEmpty && controller.isVisible, "Swipe release must not execute")
        precondition(controller.processLayerKey(key(49, repeatKey: true)))
        precondition(executed.isEmpty)
        precondition(controller.processLayerKey(key(49)))
        try await Task.sleep(nanoseconds: 80_000_000)
        precondition(executed == [mute.action] && !controller.isVisible, "Space executes selected ID exactly once")

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
        print("Voice API validation, credentials, bounded audio, cancellation, catalog, swipe/confirm runtime, and HUD render: PASS")
    }
}
