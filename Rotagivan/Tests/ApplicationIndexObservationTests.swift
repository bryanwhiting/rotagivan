import AppKit

private final class ObservationScanCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var calls: Int { lock.lock(); defer { lock.unlock() }; return value }
    func scan(_ roots: [URL]) -> ExplorerApplicationCatalog.ScanResult {
        dispatchPrecondition(condition: .notOnQueue(.main))
        lock.lock(); value += 1; lock.unlock()
        return ExplorerApplicationCatalog.scanWithStatus(roots: roots)
    }
}

private final class ObservationEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [String] = []
    func append(_ paths: [String], _ flags: [UInt32]) {
        lock.lock(); defer { lock.unlock() }
        records += zip(paths, flags).map { "\($0.0) flags=\($0.1)" }
        records = Array(records.suffix(32))
    }
    var description: String { lock.lock(); defer { lock.unlock() }; return records.joined(separator: " | ") }
    func decision(_ path: String, _ roots: [String], _ relevant: Bool) {
        lock.lock(); defer { lock.unlock() }
        records.append("decision path=\(path), roots=\(roots), relevant=\(relevant)")
        records = Array(records.suffix(32))
    }
}

private final class ObservationCallbackCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var calls: Int { lock.lock(); defer { lock.unlock() }; return value }
    func increment() { lock.lock(); value += 1; lock.unlock() }
}

@MainActor private final class CountedNativeObservation: ApplicationIndexChangeObserving {
    let native: ApplicationIndexObservation
    let callbacks = ObservationCallbackCounter()
    init(_ native: ApplicationIndexObservation) { self.native = native }
    func start(onChange: @escaping @Sendable () -> Void, onError: @escaping @Sendable (String) -> Void) {
        let callbacks = callbacks
        native.start(onChange: { callbacks.increment(); onChange() }, onError: onError)
    }
    func stop() { native.stop() }
}

@main struct ApplicationIndexObservationTests {
    @MainActor static func main() async throws {
        let manager = FileManager.default
        let base = manager.temporaryDirectory.appendingPathComponent("Rotagivan.ApplicationObservation.\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: base, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: base) }
        let home = base.appendingPathComponent("SyntheticHome", isDirectory: true)
        try manager.createDirectory(at: home, withIntermediateDirectories: false)
        let root = home.appendingPathComponent("Applications", isDirectory: true)
        precondition(!manager.fileExists(atPath: root.path), "Fixture begins with the optional user Applications root absent")
        let physicalRoot = home.resolvingSymlinksInPath().appendingPathComponent("Applications").path
        precondition(ApplicationIndexObservation.matches(path: physicalRoot + "/Deleted.app/Contents/Info.plist", roots: [physicalRoot]),
            "A deleted event's raw physical spelling must match without consulting disk")
        precondition(ApplicationIndexObservation.matches(path: physicalRoot, roots: [physicalRoot]))
        precondition(!ApplicationIndexObservation.matches(path: physicalRoot + "-unrelated/Other.app", roots: [physicalRoot]),
            "Root matching requires a path component boundary")
        func app(_ url: URL, id: String, name: String) throws {
            let contents = url.appendingPathComponent("Contents", isDirectory: true)
            try manager.createDirectory(at: contents, withIntermediateDirectories: true)
            let plist: [String: Any] = ["CFBundleIdentifier": id, "CFBundleDisplayName": name,
                "CFBundleName": name, "CFBundlePackageType": "APPL", "CFBundleVersion": "1"]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"), options: .atomic)
        }
        var diagnostics: () -> String = { "" }
        func eventually(_ condition: () -> Bool, _ message: String, details: (() -> String)? = nil) async {
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while ContinuousClock.now < deadline {
                if condition() { return }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            preconditionFailure(message + ": " + (details?() ?? diagnostics()))
        }
        let counter = ObservationScanCounter()
        let eventLog = ObservationEventLog()
        let observer = CountedNativeObservation(ApplicationIndexObservation(roots: [root], events: { eventLog.append($0, $1) },
            decisions: { eventLog.decision($0, $1, $2) }))
        let index = VoiceApplicationIndex(refreshInterval: 60, debounceInterval: 0.05,
            observation: observer, scan: { counter.scan([root]) })
        diagnostics = { "scans=\(counter.calls), callbacks=\(observer.callbacks.calls), refreshing=\(index.isRefreshing), apps=\(index.applications), scanError=\(String(describing: index.refreshError)), watcherError=\(String(describing: index.observationError)), events=\(eventLog.description)" }
        index.start()
        await eventually({ index.lastRefreshedAt != nil && !index.isRefreshing }, "Nonblocking startup scan must finish without an Applications directory")
        precondition(index.applications.isEmpty && index.refreshError == nil && index.observationError == nil)
        let initialCalls = counter.calls
        try app(root.appendingPathComponent("Created.app"), id: "fixture.created", name: "Created")
        await eventually({ index.applications.contains { $0.bundleID == "fixture.created" } },
            "Native observation must notice creation of an initially absent Applications root")
        precondition(counter.calls > initialCalls)
        let nested = root.appendingPathComponent("Tools", isDirectory: true).appendingPathComponent("Nested.app", isDirectory: true)
        try app(nested, id: "fixture.nested", name: "Nested")
        await eventually({ index.applications.contains { $0.bundleID == "fixture.nested" } },
            "Native subtree observation must discover apps in nested folders")
        // Build outside the watched root, then replace by rename as installers do.
        let replacement = base.appendingPathComponent("Staged.app", isDirectory: true)
        try app(replacement, id: "fixture.replacement", name: "Replacement")
        try manager.moveItem(at: nested, to: base.appendingPathComponent("Old.app", isDirectory: true))
        try manager.moveItem(at: replacement, to: nested)
        await eventually({ index.applications.contains { $0.bundleID == "fixture.replacement" && $0.name == "Replacement" } &&
            !index.applications.contains { $0.bundleID == "fixture.nested" } },
            "Atomic app replacement must refresh identity and display name at the same path",
            details: { "scans=\(counter.calls), callbacks=\(observer.callbacks.calls), refreshing=\(index.isRefreshing), apps=\(index.applications), scanError=\(String(describing: index.refreshError)), watcherError=\(String(describing: index.observationError)), events=\(eventLog.description)" })
        let callbacksBeforeRemoval = observer.callbacks.calls
        try manager.removeItem(at: root.appendingPathComponent("Created.app", isDirectory: true))
        await eventually({ !index.applications.contains { $0.bundleID == "fixture.created" } },
            "Native removal events must remove uninstalled apps from the complete snapshot",
            details: { "scans=\(counter.calls), callbacks=\(observer.callbacks.calls) beforeRemoval=\(callbacksBeforeRemoval), refreshing=\(index.isRefreshing), apps=\(index.applications), scanError=\(String(describing: index.refreshError)), watcherError=\(String(describing: index.observationError)), events=\(eventLog.description)" })
        await eventually({ !index.isRefreshing }, "Removal scan must settle before unrelated-home filtering check")
        try? await Task.sleep(nanoseconds: 300_000_000)
        let beforeUnrelated = counter.calls
        let unrelated = home.appendingPathComponent("Unrelated", isDirectory: true)
        try manager.createDirectory(at: unrelated, withIntermediateDirectories: false)
        try Data("synthetic unrelated change".utf8).write(to: unrelated.appendingPathComponent("fixture.txt"))
        try? await Task.sleep(nanoseconds: 500_000_000)
        precondition(counter.calls == beforeUnrelated,
            "Watching a root's parent must not scan for unrelated home-directory changes")
        let complete = index.applications
        await index.load()
        precondition(index.applications == complete, "A voice cache read must keep the stable complete snapshot")
        index.stop()
        let stoppedCalls = counter.calls
        try app(root.appendingPathComponent("Stopped.app"), id: "fixture.stopped", name: "Stopped")
        try? await Task.sleep(nanoseconds: 500_000_000)
        precondition(counter.calls == stoppedCalls && index.applications == complete,
            "Stopped native observation must not scan or publish later filesystem changes")
        index.start()
        await eventually({ index.applications.contains { $0.bundleID == "fixture.stopped" } },
            "Restart startup must discover changes made while observation was stopped")
        precondition(index.observationError == nil && index.refreshError == nil,
            "A healthy synthetic-root watcher must remain distinct from scan error status")
        index.stop()
        // A user Applications directory may itself be a symlink. Retargeting
        // must rebind recursive observation, not just trigger one lucky rescan.
        let aliasHome = base.appendingPathComponent("AliasHome", isDirectory: true)
        try manager.createDirectory(at: aliasHome, withIntermediateDirectories: false)
        let alias = aliasHome.appendingPathComponent("Applications", isDirectory: true)
        let firstTarget = base.appendingPathComponent("TargetOne", isDirectory: true)
        let secondTarget = base.appendingPathComponent("TargetTwo", isDirectory: true)
        try app(firstTarget.appendingPathComponent("First.app"), id: "fixture.firstTarget", name: "First target")
        try app(secondTarget.appendingPathComponent("Second.app"), id: "fixture.secondTarget", name: "Second target")
        try manager.createSymbolicLink(at: alias, withDestinationURL: firstTarget)
        let aliasCounter = ObservationScanCounter()
        let aliasEvents = ObservationEventLog()
        let aliasObserver = CountedNativeObservation(ApplicationIndexObservation(roots: [alias], events: { aliasEvents.append($0, $1) },
            decisions: { aliasEvents.decision($0, $1, $2) }))
        let aliasIndex = VoiceApplicationIndex(refreshInterval: 60, debounceInterval: 0.05,
            observation: aliasObserver, scan: { aliasCounter.scan([alias]) })
        diagnostics = { "aliasScans=\(aliasCounter.calls), callbacks=\(aliasObserver.callbacks.calls), refreshing=\(aliasIndex.isRefreshing), apps=\(aliasIndex.applications), scanError=\(String(describing: aliasIndex.refreshError)), watcherError=\(String(describing: aliasIndex.observationError)), events=\(aliasEvents.description)" }
        aliasIndex.start()
        await eventually({ aliasIndex.applications.contains { $0.bundleID == "fixture.firstTarget" } },
            "Initial symlink target must be indexed")
        try manager.removeItem(at: alias)
        try manager.createSymbolicLink(at: alias, withDestinationURL: secondTarget)
        await eventually({ aliasIndex.applications.contains { $0.bundleID == "fixture.secondTarget" } &&
            !aliasIndex.applications.contains { $0.bundleID == "fixture.firstTarget" } },
            "Replacing a watched Applications symlink must index its new target")
        try app(secondTarget.appendingPathComponent("Tools", isDirectory: true).appendingPathComponent("Later.app"),
            id: "fixture.laterTarget", name: "Later target")
        await eventually({ aliasIndex.applications.contains { $0.bundleID == "fixture.laterTarget" } },
            "Observation must rebind so later nested creations in the new target are noticed")
        await eventually({ !aliasIndex.isRefreshing }, "New symlink target scans must settle")
        try? await Task.sleep(nanoseconds: 300_000_000)
        let beforeOldTargetChange = aliasCounter.calls
        try app(firstTarget.appendingPathComponent("Obsolete.app"), id: "fixture.obsoleteTarget", name: "Obsolete target")
        try? await Task.sleep(nanoseconds: 500_000_000)
        precondition(aliasCounter.calls == beforeOldTargetChange && !aliasIndex.applications.contains { $0.bundleID == "fixture.obsoleteTarget" },
            "The old symlink target must not continue triggering scans after rebinding")
        aliasIndex.stop()
        print("Native application observation passed absent-root creation, nested apps, atomic replacement, removal, stable cache, stop, and restart using synthetic temporary bundles only.")
    }
}
