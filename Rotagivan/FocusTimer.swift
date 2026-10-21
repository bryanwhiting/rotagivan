import AppKit
import SwiftUI

/// The timer HUD's choices: tap the center for 25 minutes, or swipe.
struct FocusTimerPreset: Equatable {
    let direction: SwipeDirection
    let minutes: Int
    var title: String { "\(minutes) min" }

    static let centerMinutes = 25
    static let swipes: [Self] = [
        Self(direction: .up, minutes: 5), Self(direction: .topRight, minutes: 10),
        Self(direction: .right, minutes: 15), Self(direction: .bottomRight, minutes: 20),
        Self(direction: .down, minutes: 30), Self(direction: .bottomLeft, minutes: 45),
        Self(direction: .left, minutes: 55), Self(direction: .topLeft, minutes: 60)
    ]
}

/// One timer at a time. Starting another replaces it. When it ends, every
/// screen's edges glow and flash until the user dismisses the alert.
@MainActor final class FocusTimer: ObservableObject {
    static let shared = FocusTimer()
    @Published private(set) var endsAt: Date?
    @Published private(set) var minutes = 0
    private var timer: Timer?
    private var alert: FocusTimerAlert?
    /// Replaced in tests so nothing is drawn on screen.
    var presentAlert: (Int) -> Void = { minutes in FocusTimer.shared.showAlert(minutes: minutes) }

    var remaining: TimeInterval? { endsAt.map { max(0, $0.timeIntervalSinceNow) } }

    func start(minutes: Int, now: Date = Date()) {
        guard (1...240).contains(minutes) else { return }
        cancel()
        alert?.close(); alert = nil
        self.minutes = minutes
        let end = now.addingTimeInterval(TimeInterval(minutes * 60))
        endsAt = end
        let timer = Timer(fire: end, interval: 0, repeats: false) { _ in
            Task { @MainActor in FocusTimer.shared.finish() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func cancel() {
        timer?.invalidate(); timer = nil
        endsAt = nil
    }

    func finish() {
        guard endsAt != nil else { return }
        let finished = minutes
        cancel()
        presentAlert(finished)
    }

    private func showAlert(minutes: Int) {
        alert?.close()
        let alert = FocusTimerAlert(minutes: minutes, onDone: { [weak self] in
            self?.alert?.close(); self?.alert = nil
        }, onSnooze: { [weak self] in
            self?.alert?.close(); self?.alert = nil
            self?.start(minutes: 5)
        })
        self.alert = alert
        alert.show()
    }
}

/// Glowing edge windows on every screen (click-through) plus one small
/// panel with the buttons on the main screen.
@MainActor final class FocusTimerAlert {
    private var windows: [NSWindow] = []
    private let minutes: Int
    private let onDone: () -> Void
    private let onSnooze: () -> Void

    init(minutes: Int, onDone: @escaping () -> Void, onSnooze: @escaping () -> Void) {
        self.minutes = minutes; self.onDone = onDone; self.onSnooze = onSnooze
    }

    func show() {
        NSSound(named: "Glass")?.play()
        for screen in NSScreen.screens {
            let window = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = false
            window.ignoresMouseEvents = true
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window.contentView = NSHostingView(rootView: FocusTimerGlow())
            window.setFrame(screen.frame, display: true)
            window.orderFrontRegardless()
            windows.append(window)
        }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let size = NSSize(width: 340, height: 150)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = NSHostingView(rootView: FocusTimerAlertCard(minutes: minutes, onDone: onDone, onSnooze: onSnooze))
        let visible = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2))
        panel.orderFrontRegardless()
        windows.append(panel)
    }

    func close() {
        windows.forEach { $0.orderOut(nil) }
        windows = []
    }
}

struct FocusTimerGlow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var flashes = 0
    @State private var white = false
    @State private var breathing = false
    private let colors: [Color] = [RotaTokens.glassBlue, Color(red: 0.80, green: 0.91, blue: 1), RotaTokens.glassBlue.opacity(0.7), Color(red: 0.80, green: 0.91, blue: 1), RotaTokens.glassBlue]

    var body: some View {
        GeometryReader { geometry in
            let shape = Rectangle()
            ZStack {
                shape.strokeBorder(AngularGradient(colors: colors, center: .center), lineWidth: 26).blur(radius: 28)
                shape.strokeBorder(AngularGradient(colors: colors, center: .center), lineWidth: 10).blur(radius: 6)
                shape.strokeBorder(Color.white, lineWidth: 14).blur(radius: 10).opacity(white ? 1 : 0)
            }
            // One GPU raster for the blurred ring; only its opacity animates.
            .drawingGroup()
            .opacity(breathing ? 0.65 : 1)
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .ignoresSafeArea()
        .onAppear(perform: animate)
        .accessibilityHidden(true)
    }

    /// Three white flashes, then a slow glow until dismissed. Reduce Motion
    /// keeps a steady glow with no flashing.
    private func animate() {
        guard !reduceMotion else { return }
        func flash() {
            guard flashes < 6 else {
                withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { breathing = true }
                return
            }
            withAnimation(.easeInOut(duration: 0.18)) { white.toggle() }
            flashes += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: flash)
        }
        flash()
    }
}

struct FocusTimerAlertCard: View {
    let minutes: Int
    let onDone: () -> Void
    let onSnooze: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Label("\(minutes)-minute timer done", systemImage: "timer").font(.title3.weight(.semibold))
                .foregroundStyle(.primary).symbolRenderingMode(.hierarchical).tint(RotaTokens.glassBlue)
            HStack(spacing: 10) {
                Button("+5 min", action: onSnooze).buttonStyle(.rotaSecondary)
                    .accessibilityIdentifier("timer-snooze")
                Button("Done", action: onDone).buttonStyle(.rotaPrimary)
                    .accessibilityIdentifier("timer-done")
            }
        }
        .padding(24)
        .frame(width: 340, height: 150)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(LinearGradient(colors: [.white.opacity(0.55), RotaTokens.glassBlue.opacity(0.35), .white.opacity(0.12)], startPoint: .topLeading, endPoint: .bottomTrailing)))
        .shadow(color: RotaTokens.glassBlue.opacity(0.35), radius: 18)
    }
}
