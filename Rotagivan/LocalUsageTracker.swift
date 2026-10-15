import AppKit
import Carbon
import Combine
import CryptoKit

final class LocalUsageTracker: ObservableObject {
    static let shared = LocalUsageTracker()
    static let storageURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Rotagivan/Activity/usage.sqlite")
    private let defaults: UserDefaults
    private let databaseURL: URL
    private let monitorSystem: Bool
    @Published private(set) var enabled: Bool
    @Published private(set) var websites: Bool
    @Published private(set) var personalize: Bool
    @Published private(set) var status = "Tracking is off"
    @Published private(set) var error: String?
    @Published private(set) var report = UsageReport()
    @Published private(set) var today = UsageReport()
    @Published private(set) var actions: [UsageActionTotal] = []
    @Published private(set) var hotkeys: [UsageActionTotal] = []
    @Published private(set) var catalogue: [UsageActionTotal] = []
    var actionCatalogue: () -> [UsageActionTotal] = { [] }
    @Published var day = Date() { didSet { refresh() } }
    private let writer = DispatchQueue(label: "local.rotagivan.activity.storage", qos: .utility)
    private let browser = DispatchQueue(label: "local.rotagivan.activity.chrome", qos: .utility)
    private var database: UsageDatabase? // Access only on writer.
    private var clock = UsageClock()
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var blocked: Set<String> = []
    private var host: String?
    private var appID: String?
    private var browserBusy = false
    private var generation = 0
    private var sampleCount = 0
    private var lastExternalApp: String?
    private var prediction = UsagePrediction()
    private var started = false
    private var clearing = false
    init(defaults: UserDefaults = UserDefaults(suiteName: "local.rotagivan.activity")!,
         databaseURL: URL = LocalUsageTracker.storageURL, monitorSystem: Bool = true) {
        self.defaults = defaults; self.databaseURL = databaseURL; self.monitorSystem = monitorSystem
        enabled = defaults.bool(forKey: "enabled")
        websites = defaults.bool(forKey: "chromeDomains")
        personalize = defaults.bool(forKey: "personalize")
    }
    func start() {
        guard !started else { return }; started = true
        // Native UI tests can use synthetic data without touching system activity,
        // real preferences, browser permissions, or the production database.
        guard monitorSystem else { return }
        RotaActionUsage.enabled = enabled
        for (name, hotkey) in [("local.rotagivan.action.invoked", false), ("local.rotagivan.hotkey.invoked", true)] {
            observers.append(NotificationCenter.default.addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] note in
                guard let self, self.enabled, !self.clearing, self.error == nil, self.blocked.isEmpty, !self.sessionLocked() else { return }
                if hotkey, let key = note.object as? RecordedShortcut {
                    let id = "key_" + SHA256.hash(data: Data(key.identity.utf8)).map { String(format: "%02x", $0) }.joined()
                    self.record(id: id, name: key.readableCombination, category: "hotkey")
                } else if let action = note.object as? BindingAction {
                    self.record(id: VoiceRegisteredAction.id(for: action), name: Self.actionName(action), category: "action")
                }
            })
        }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in self?.tick() })
        let pairs: [(Notification.Name, Notification.Name, String)] = [
            (NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification, "sleep"),
            (NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification, "display"),
            (NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification, "session")]
        for (stop, resume, reason) in pairs {
            observers.append(center.addObserver(forName: stop, object: nil, queue: .main) { [weak self] _ in self?.suspend(reason) })
            observers.append(center.addObserver(forName: resume, object: nil, queue: .main) { [weak self] _ in
                self?.blocked.remove(reason); self?.clock.reset(); self?.tick()
            })
        }
        let distributed = DistributedNotificationCenter.default()
        observers.append(distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in self?.suspend("lock") })
        observers.append(distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            self?.blocked.remove("lock"); self?.clock.reset(); self?.tick()
        })
        LauncherUsageOrder.install { [weak self] matches, query in
            // Search can be invoked off-main; consult a separately locked snapshot.
            self?.ranking.order(matches, query: query) ?? matches
        }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.tick() }
        tick(); refresh()
    }
    private let ranking = UsageRankingSnapshot()
    func setEnabled(_ value: Bool) {
        tick(); enabled = value; defaults.set(value, forKey: "enabled")
        RotaActionUsage.enabled = value; updateRanking()
        generation += 1; clock.reset(); host = nil; appID = nil
        if value { error = nil }; tick(); refresh()
    }
    func setWebsites(_ value: Bool) {
        tick(); websites = value; defaults.set(value, forKey: "chromeDomains")
        generation += 1; host = nil; tick()
    }
    func setPersonalize(_ value: Bool) {
        personalize = value; defaults.set(value, forKey: "personalize"); updateRanking()
    }
    private func updateRanking() { ranking.update(prediction, current: lastExternalApp, enabled: enabled && personalize && !clearing) }
    static func actionName(_ action: BindingAction) -> String {
        if action.kind == .openURL { return UsagePrivacy.host(action.url ?? "").map { "Open " + $0 } ?? "Open website" }
        return String(action.title.prefix(256))
    }
    private func record(id: String, name: String, category: String) {
        let now = Date().timeIntervalSince1970
        enqueue { db in try db.recordAction(id: id, name: name, category: category, at: now) }
    }
    private func suspend(_ reason: String) {
        tick(); blocked.insert(reason); clock.reset(); host = nil; generation += 1
        status = "Paused while this Mac is inactive"; refresh()
    }
    private func sessionLocked() -> Bool {
        let values = CGSessionCopyCurrentDictionary() as? [String: Any]
        return (values?["CGSSessionScreenIsLocked"] as? Bool) == true || (values?[kCGSessionOnConsoleKey as String] as? Bool) == false
    }
    private func tick(captureSite: Bool = true) {
        guard enabled, !clearing, error == nil, blocked.isEmpty, !sessionLocked() else {
            clock.reset(); host = nil
            status = error != nil ? "Tracking paused: storage unavailable" : (enabled ? "Paused" : "Tracking is off")
            return
        }
        let running = NSWorkspace.shared.frontmostApplication
        let app = running.flatMap { candidate -> UsageApp? in
            guard candidate.activationPolicy == .regular, let id = candidate.bundleIdentifier else { return nil }
            return UsageApp(id: id, name: candidate.localizedName ?? id)
        }
        if appID != app?.id { host = nil; appID = app?.id; generation += 1 }
        if let app, app.id != Bundle.main.bundleIdentifier { lastExternalApp = app.id; updateRanking() }
        // kCGAnyInputEventType is the UInt32.max sentinel, not .null (event 0).
        // Count keyboard, mouse, and tablet input, without inspecting their data.
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: UInt32.max)!)
        let now = Date().timeIntervalSince1970
        let update = clock.sample(.init(wall: now, uptime: ProcessInfo.processInfo.systemUptime, idle: idle, app: app, host: host))
        if update.interval != nil || update.trimAfter != nil {
            enqueue { db in
                if let interval = update.interval { try db.append(interval) }
                if let trim = update.trimAfter { try db.trim(after: trim) }
            }
        }
        status = idle >= 900 ? "Paused · 15 minutes without input" : "Tracking the active app"
        if idle >= 900 { host = nil; generation += 1 }
        sampleCount += 1
        if sampleCount % 6 == 0 || update.trimAfter != nil { refresh() }
        if captureSite, websites, idle < 900, running?.bundleIdentifier == "com.google.Chrome", let pid = running?.processIdentifier {
            captureChrome(pid: pid)
        }
    }
    private func enqueue(_ work: @escaping (UsageDatabase) throws -> Void) {
        writer.async { [weak self] in
            guard let self else { return }
            do {
                if self.database == nil { self.database = try UsageDatabase(url: self.databaseURL) }
                if let db = self.database { try work(db) }
            } catch {
                DispatchQueue.main.async {
                    self.error = error.localizedDescription; self.clock.reset(); self.generation += 1
                    self.clearing = false
                    self.status = "Tracking paused: storage unavailable"
                }
            }
        }
    }
    func refresh() {
        let date = day, now = Date(), version = generation
        catalogue = actionCatalogue()
        let calendar = Calendar.current
        guard let range = calendar.dateInterval(of: .day, for: date), let todayRange = calendar.dateInterval(of: .day, for: now) else { return }
        enqueue { [weak self] db in
            let report = UsageDatabase.report(try db.intervals(from: range.start.timeIntervalSince1970, to: range.end.timeIntervalSince1970))
            let today = UsageDatabase.report(try db.intervals(from: todayRange.start.timeIntervalSince1970, to: todayRange.end.timeIntervalSince1970))
            let actions = try db.actions(from: range.start.timeIntervalSince1970, to: range.end.timeIntervalSince1970, category: "action")
            let hotkeys = try db.actions(from: range.start.timeIntervalSince1970, to: range.end.timeIntervalSince1970, category: "hotkey")
            let prediction = UsageDatabase.prediction(try db.intervals(from: now.addingTimeInterval(-30 * 86400).timeIntervalSince1970, to: now.timeIntervalSince1970), now: now.timeIntervalSince1970)
            DispatchQueue.main.async {
                guard let self, !self.clearing, version == self.generation else { return }
                if Calendar.current.isDate(self.day, inSameDayAs: date) { self.report = report }
                self.today = today; self.prediction = prediction; self.updateRanking()
                self.actions = actions; self.hotkeys = hotkeys
            }
        }
    }
    func clearHistory() {
        guard !clearing else { return }
        generation += 1; clearing = true; clock.reset(); host = nil
        prediction = UsagePrediction(); report = UsageReport(); today = UsageReport(); updateRanking()
        actions = []; hotkeys = []
        enqueue { [weak self] db in
            try db.clear()
            DispatchQueue.main.async { self?.clearing = false; self?.error = nil; self?.tick(); self?.refresh() }
        }
    }
    func prepareToQuit() async {
        tick(captureSite: false); timer?.invalidate(); timer = nil; clock.reset(); generation += 1
        RotaActionUsage.enabled = false
        await withCheckedContinuation { continuation in writer.async { continuation.resume() } }
    }
    /// Permission may be requested only by this explicit button, never a poll.
    func allowChrome() {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").first != nil else {
            status = "Open Chrome, then allow website access."; return
        }
        browser.async { [weak self] in
            let code = Self.chromePermission(ask: true)
            DispatchQueue.main.async {
                if code == noErr { self?.setWebsites(true) }
                else { self?.status = "Chrome access not allowed. App time still works." }
            }
        }
    }
    private static func chromePermission(ask: Bool) -> OSStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.google.Chrome")
        return AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, ask)
    }
    private func captureChrome(pid: pid_t) {
        guard !browserBusy else { return }; browserBusy = true
        let token = generation, requested = ProcessInfo.processInfo.systemUptime
        browser.async { [weak self] in
            var domain: String?
            // No prompt from background polling. No incognito URL is requested.
            if Self.chromePermission(ask: false) == noErr {
                let source = """
                with timeout of 1 seconds
                    tell application "Google Chrome"
                        if (count of windows) = 0 then return ""
                        if mode of front window is "incognito" then return ""
                        return URL of active tab of front window
                    end tell
                end timeout
                """
                var failure: NSDictionary?
                let value = NSAppleScript(source: source)?.executeAndReturnError(&failure).stringValue
                if failure == nil, let value { domain = UsagePrivacy.host(value) }
            }
            let captured = domain
            DispatchQueue.main.async {
                guard let self else { return }; self.browserBusy = false
                guard token == self.generation, self.enabled, self.websites, self.blocked.isEmpty,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                      ProcessInfo.processInfo.systemUptime - requested < 3 else { return }
                self.tick(captureSite: false); self.host = captured
                // Start the new domain interval now rather than attributing past time to it.
                self.tick(captureSite: false)
            }
        }
    }
}

/// Immutable-in-effect snapshots behind a lock: no database, network, or history
/// export on the keystroke path. Text matching still determines eligibility.
private final class UsageRankingSnapshot {
    private let lock = NSLock()
    private var prediction = UsagePrediction(), current: String?, enabled = false
    func update(_ value: UsagePrediction, current: String?, enabled: Bool) {
        lock.lock(); defer { lock.unlock() }; prediction = value; self.current = current; self.enabled = enabled
    }
    func order(_ matches: [LauncherAction], query: String) -> [LauncherAction] {
        lock.lock(); let model = prediction, current = current, enabled = enabled; lock.unlock()
        guard enabled else { return matches }
        let query = query.lowercased()
        // Only reorder small, equally text-relevant app groups. Never promote a
        // nonmatch or displace an exact name with a more frequently used app.
        func bucket(_ action: LauncherAction) -> Int {
            let name = action.name.lowercased()
            return name == query ? 0 : (name.hasPrefix(query) ? 1 : (name.contains(query) ? 2 : 3))
        }
        let candidates = matches.map { action -> UsagePrediction.Candidate in
            var id: String?
            if case .app(let app) = action.target { id = app.bundleID }
            return UsagePrediction.Candidate(appID: id, textBucket: bucket(action))
        }
        return model.order(candidates, after: current).map { matches[$0] }
    }
}
