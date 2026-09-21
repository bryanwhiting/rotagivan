import AppKit
import SwiftUI

@MainActor private final class PreviewFixture: ObservableObject {
    @Published var parentRevision = 0
    @Published var enabled = true
    @Published var active = true
    @Published var telemetry = CursorTelemetry()
}

private struct PreviewHost: View {
    @ObservedObject var fixture: PreviewFixture
    var body: some View {
        ZStack {
            Color.white
            if fixture.enabled && fixture.active {
                LiveCursorOverlay(telemetry: fixture.telemetry, profileID: 1, inputRange: 8_000,
                    size: CGSize(width: 320, height: 170), inset: 12)
                    // Reconstruct the child at HID rate without changing its
                    // identity or rendered content. Sampling must not restart.
                    .allowsHitTesting(fixture.parentRevision.isMultiple(of: 2))
            }
        }
        .frame(width: 320, height: 170)
        .preferredColorScheme(.light)
    }
}

@main struct LiveCursorPreviewTests {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let fixture = PreviewFixture()
        let host = NSHostingView(rootView: PreviewHost(fixture: fixture))
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 170),
            styleMask: [.titled], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = host
        panel.orderFront(nil)
        defer { panel.orderOut(nil); panel.close() }
        let ticker = Timer(timeInterval: 1.0 / 125, repeats: true) { _ in
            MainActor.assumeIsolated { fixture.parentRevision += 1 }
        }
        RunLoop.main.add(ticker, forMode: .common)
        defer { ticker.invalidate() }

        func snapshot(_ name: String) throws -> Data {
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
            host.layoutSubtreeIfNeeded()
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let data = bitmap.representation(using: .png, properties: [:])!
            if CommandLine.arguments.count > 1 {
                try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1])
                    .appendingPathComponent("live-\(name).png"))
            }
            return data
        }

        let empty = try snapshot("idle")
        fixture.telemetry.record(CursorSample(profileID: 1, speed: 1_500, gain: 0.4, touching: true))
        let slow = try snapshot("slow")
        precondition(slow != empty, "Live must show input even while its parent rebuilds at 125 Hz")
        fixture.telemetry.record(CursorSample(profileID: 1, speed: 6_000, gain: 2.0, touching: true))
        let fast = try snapshot("fast")
        precondition(fast != empty && fast != slow, "Live must keep sampling, not freeze on its first value")
        fixture.telemetry.endTouch()
        let lifted = try snapshot("lifted")
        precondition(lifted == empty, "Lift must clear the marker")
        fixture.telemetry.record(CursorSample(profileID: 2, speed: 1_500, gain: 0.4, touching: true))
        let otherLayer = try snapshot("other-layer")
        precondition(otherLayer == empty, "Do not plot another layer's sample")
        fixture.telemetry.record(CursorSample(profileID: 1, speed: 1_500, gain: 0.4, touching: true))
        fixture.enabled = false
        let paused = try snapshot("paused")
        precondition(paused == empty, "Live off removes the sampling overlay")
        fixture.enabled = true
        let resumed = try snapshot("resumed")
        precondition(resumed == slow, "Live on resumes from the newest sample")
        fixture.active = false
        let inactive = try snapshot("inactive")
        precondition(inactive == empty, "Inactive layers must not sample or draw")
        fixture.active = true
        let active = try snapshot("active")
        precondition(active == slow)
        // A replacement buffer must restart the task, not retain the old input.
        let replacement = CursorTelemetry()
        replacement.record(CursorSample(profileID: 1, speed: 6_000, gain: 2.0, touching: true))
        fixture.telemetry = replacement
        let replaced = try snapshot("replaced-buffer")
        precondition(replaced == fast)
        precondition(fixture.parentRevision > 100, "Exercise sustained parent updates")
        print("Live preview rendering passed: 125 Hz parent rebuilds, changing samples, lift, layer filtering, off/on, inactive/active, replacement buffer.")
    }
}
