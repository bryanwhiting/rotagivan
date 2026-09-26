import AppKit
import SwiftUI

@MainActor private final class HUDMicrophone: VoiceAudioCapturing {
    let buffer = VoiceAudioBuffer()
    func start() throws { buffer.append(Data(repeating: 1, count: 32000), rms: 0.12) }
    func stop() {}
}
private final class HUDCloud: VoiceCloudServing {
    let decision: VoiceDecision
    let delay: UInt64
    let transcriptionError: Error?
    init(_ decision: VoiceDecision, delay: UInt64 = 50_000_000, transcriptionError: Error? = nil) {
        self.decision = decision; self.delay = delay; self.transcriptionError = transcriptionError
    }
    func transcribe(_ wav: Data) async throws -> String {
        if let transcriptionError { throw transcriptionError }
        try await Task.sleep(nanoseconds: delay)
        return "Open the project workspace and review all the very long notes for the upcoming presentation with the design team"
    }
    func classify(_ transcript: String, catalog: [VoiceRegisteredAction]) async throws -> VoiceDecision { decision }
}

@main struct VoiceHUDUISmoke {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        let catalog = [
            VoiceRegisteredAction(action: .openApp(bundleID: "fixture.slack", name: "Slack"), detail: "Fixture",
                actionName: "Open the very long project workspace and review upcoming presentation notes"),
            VoiceRegisteredAction(action: .media(.mute), detail: "Fixture"),
            VoiceRegisteredAction(action: .media(.playPause), detail: "Fixture")
        ]
        let ready = VoiceDecision(matches: zip(catalog, [0.85, 0.09, 0.04]).map {
            VoiceMatch(record: $0.0, probability: $0.1)
        }, confidence: 0.85, noMatch: false)
        func fixture(_ decision: VoiceDecision = ready) -> VoiceSession {
            let session = VoiceSession()
            // Each rendered scenario is independent; production sessions share
            // admission so a retry cannot bypass an old transport still draining.
            session.pipelineAdmission = VoicePipelineAdmission()
            session.makeCloud = { HUDCloud(decision) }
            session.makeMicrophone = { HUDMicrophone() }
            session.requestPermission = { true }
            return session
        }
        func waitFor(_ phase: VoiceSession.Phase, in session: VoiceSession) throws {
            for _ in 0..<100 {
                if session.phase == phase { return }
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
            preconditionFailure("Fixture did not reach \(phase)")
        }
        let preparing = fixture()
        let listening = fixture()
        let listeningMicrophone = HUDMicrophone()
        listening.makeMicrophone = { listeningMicrophone }
        listening.start(catalog: catalog)
        try waitFor(.listening, in: listening)
        let result = fixture(); result.start(catalog: catalog)
        try waitFor(.listening, in: result); result.finishListening()
        try waitFor(.ready, in: result)
        let matching = fixture()
        matching.makeCloud = { HUDCloud(ready, delay: 60_000_000_000) }
        matching.start(catalog: catalog)
        try waitFor(.listening, in: matching); matching.finishListening()
        precondition(matching.phase == .matching)
        let noMatch = fixture(VoiceDecision(matches: [], confidence: 0.8, noMatch: true))
        noMatch.receive(VoiceDecision(matches: [], confidence: 0.8, noMatch: true), final: true)
        let failed = fixture()
        failed.fail(VoiceError.message("Microphone access is off. Enable Rotagivan in System Settings → Privacy & Security → Microphone, then try again. Nothing was run."))
        let timeout = fixture(); timeout.fail(VoiceError.message("No speech heard. Tap the center to retry."))
        let disconnected = fixture()
        disconnected.makeCloud = { HUDCloud(ready, transcriptionError: URLError(.notConnectedToInternet)) }
        disconnected.start(catalog: catalog)
        try waitFor(.listening, in: disconnected); disconnected.finishListening()
        try waitFor(.failed, in: disconnected)
        precondition(disconnected.selectedMatch == nil && disconnected.decision == nil)
        precondition(disconnected.message.contains("connection") && disconnected.message.contains("Nothing was run"))
        let cancelled = fixture(); cancelled.cancel()
        let states = [("preparing", preparing), ("listening", listening), ("matching", matching), ("ready", result),
            ("no-match", noMatch), ("permission-error", failed), ("timeout", timeout),
            ("connection-error", disconnected), ("cancelled", cancelled)]
        defer { listening.cancel(); result.cancel(); matching.cancel(); disconnected.cancel() }
        func elements(_ object: Any) -> [AnyObject] {
            let element = object as AnyObject
            return [element] + (element.accessibilityChildren?() ?? []).flatMap(elements)
        }
        for theme in ExplorerTheme.allCases {
            for scheme in [ColorScheme.light, .dark] {
                for (name, session) in states {
                    listeningMicrophone.buffer.append(Data(repeating: 1, count: 32), rms: 0.12)
                    var exits = 0, confirms = 0, retries = 0
                    let host = NSHostingView(rootView:
                        VoiceHUDView(session: session, theme: theme, onExit: { exits += 1 },
                            onRetry: { retries += 1 }, onConfirm: { confirms += 1 },
                            forceReduceTransparency: name == "timeout")
                        .environment(\.colorScheme, scheme))
                    let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 470, height: 520),
                        styleMask: [.borderless], backing: .buffered, defer: false)
                    panel.isReleasedWhenClosed = false; panel.contentView = host; panel.orderFront(nil)
                    RunLoop.main.run(until: Date().addingTimeInterval(0.08))
                    host.layoutSubtreeIfNeeded()
                    precondition(host.bounds.size == CGSize(width: 470, height: 520))
                    func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
                    let all = views(host).flatMap(elements)
                    let buttons = all.filter { $0.accessibilityRole?() == .button }
                    func button(_ label: String) -> AnyObject {
                        guard let button = buttons.first(where: { $0.accessibilityLabel?() == label }) else {
                            preconditionFailure("Missing button \(label); labels \(buttons.map { $0.accessibilityLabel?() ?? "" })")
                        }
                        return button
                    }
                    let cancel = button("Cancel voice mode")
                    precondition(cancel.accessibilityPerformPress?() == true); precondition(exits == 1)
                    if name == "ready" {
                        let before = button("Run selected action").accessibilityFrame?()
                        guard let right = buttons.first(where: {
                            $0.accessibilityIdentifier?() == "voice.tile.\(ExplorerSlot.right.rawValue)"
                        }) else { preconditionFailure("Right tile must have a native accessible button") }
                        precondition(right.accessibilityPerformPress?() == true)
                        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
                        precondition(session.selected == .right && confirms == 1,
                            "Clicking a directional tile must confirm immediately")
                        precondition(session.selectedMatch?.id == ready.matches[1].id)
                        let updated = views(host).flatMap(elements).first {
                            $0.accessibilityLabel?() == "Run selected action"
                        }!
                        precondition(updated.accessibilityFrame?() == before,
                            "Selection updates must preserve the wheel center")
                        precondition(updated.accessibilityPerformPress?() == true)
                        precondition(confirms == 2, "Center confirmation remains an optional alternative")
                    }
                    if name == "no-match" {
                        precondition(button("Ignore command").accessibilityPerformPress?() == true)
                        precondition(confirms == 1 && session.selectedMatch == nil)
                    }
                    if ["permission-error", "timeout", "connection-error", "cancelled"].contains(name) {
                        precondition(session.selectedMatch == nil && confirms == 0)
                        precondition(!buttons.contains { $0.accessibilityLabel?() == "Run selected action" },
                            "Failed or cancelled voice must not expose executable stale candidates")
                        precondition(button("Listen again").accessibilityPerformPress?() == true); precondition(retries == 1)
                    }
                    guard let left = buttons.first(where: {
                        $0.accessibilityIdentifier?() == "voice.tile.\(ExplorerSlot.left.rawValue)"
                    }) else { preconditionFailure("Cancel sector must be accessible in every voice state") }
                    precondition(left.accessibilityPerformPress?() == true && exits == 2,
                        "The left tile must cancel immediately in every state")
                    let center = CGPoint(x: 235, y: 250)
                    for direction in [ExplorerSlot.up, .right, .down, .left] {
                        let sector = ExplorerStarburstSector(direction: direction, innerRadius: 48,
                            outerRadius: 143, tip: theme.isFloating ? 2 : 11, halfAngle: 43, roundedRim: theme.isFloating)
                        let rect = CGRect(x: 26, y: 95, width: 418, height: 310)
                        precondition(!sector.path(in: rect).contains(center), "Sector must not intercept the center")
                        let point = ExplorerStarburstLayout.point(direction, radius: 108, center: center)
                        precondition(sector.path(in: rect).contains(point))
                        precondition([ExplorerSlot.up, .right, .down, .left].filter { other in
                            ExplorerStarburstSector(direction: other, innerRadius: 48, outerRadius: 143,
                                tip: theme.isFloating ? 2 : 11, halfAngle: 43, roundedRim: theme.isFloating).path(in: rect).contains(point)
                        }.count == 1, "Directional hit target must be unique")
                    }
                    let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let path = CommandLine.arguments[1] + "/voice-\(theme.rawValue)-\(scheme == .dark ? "dark" : "light")-\(name).png"
                    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
                    if name == "ready" { session.select(.up) }
                    panel.orderOut(nil); panel.close()
                }
            }
        }
        print("Voice HUD: all themes/light-dark, fixed geometry, long names/transcript, preparing/listening/matching/ready/no-match/permission/timeout/connection failure/cancel; forced opaque timeout, native AX tile selection/manual confirmation/retry, no executable stale error selection, stable center and exclusive sector hit targets passed. Synthetic microphone/cloud only.")
    }
}
