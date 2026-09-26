import Foundation
import CoreServices
import Darwin

protocol ApplicationIndexChangeObserving: AnyObject {
    @MainActor func start(onChange: @escaping @Sendable () -> Void,
                          onError: @escaping @Sendable (String) -> Void)
    @MainActor func stop()
}

/// Recursive filesystem notifications, filtered to application roots. Watching
/// their parents also detects creation/replacement of an optional root itself.
/// All stream setup/teardown stays off the main thread and never waits for I/O.
final class ApplicationIndexObservation: ApplicationIndexChangeObserving, @unchecked Sendable {
    static func matches(path: String, roots: [String]) -> Bool {
        roots.contains { path == $0 || path.hasPrefix($0 + "/") }
    }
    /// Preserve POSIX physical spelling: Foundation can normalize /private/var
    /// back to /var, whereas FSEvents reports /private/var. Resolve the nearest
    /// existing ancestor so optional roots retain their missing suffix too.
    static func physicalPath(_ path: String) -> String {
        var ancestor = path, suffix: [String] = []
        while true {
            if let pointer = ancestor.withCString({ realpath($0, nil) }) {
                let physical = String(cString: pointer)
                free(pointer)
                return suffix.reversed().reduce(physical) { $0 == "/" ? "/" + $1 : $0 + "/" + $1 }
            }
            guard ancestor != "/", !ancestor.isEmpty else { return path }
            suffix.append((ancestor as NSString).lastPathComponent)
            ancestor = (ancestor as NSString).deletingLastPathComponent
        }
    }
    private final class Context {
        let roots: [String]
        let changed: @Sendable () -> Void
        let reconfigure: @Sendable () -> Void
        let events: (@Sendable ([String], [UInt32]) -> Void)?
        let decisions: (@Sendable (String, [String], Bool) -> Void)?
        init(roots: [String], changed: @escaping @Sendable () -> Void,
             reconfigure: @escaping @Sendable () -> Void,
             events: (@Sendable ([String], [UInt32]) -> Void)?,
             decisions: (@Sendable (String, [String], Bool) -> Void)?) {
            self.roots = roots; self.changed = changed; self.reconfigure = reconfigure
            self.events = events
            self.decisions = decisions
        }
    }
    private let queue = DispatchQueue(label: "local.rotagivan.application-observation", qos: .utility)
    private let roots: [String]
    private let events: (@Sendable ([String], [UInt32]) -> Void)?
    private let decisions: (@Sendable (String, [String], Bool) -> Void)?
    // Accessed only on queue; serial teardown precedes subsequent setup.
    private final class StreamState: @unchecked Sendable {
        var stream: FSEventStreamRef?
        var started = false
        func tearDown() {
            guard let stream else { return }
            if started { FSEventStreamStop(stream) }
            FSEventStreamInvalidate(stream); FSEventStreamRelease(stream)
            started = false; self.stream = nil
        }
    }
    private let state = StreamState()
    @MainActor private var generation = UUID()
    @MainActor init(roots: [URL] = ExplorerApplicationCatalog.roots,
                    events: (@Sendable ([String], [UInt32]) -> Void)? = nil,
                    decisions: (@Sendable (String, [String], Bool) -> Void)? = nil) {
        self.roots = roots.map { $0.path }
        self.events = events
        self.decisions = decisions
    }
    @MainActor func start(onChange: @escaping @Sendable () -> Void,
                          onError: @escaping @Sendable (String) -> Void) {
        generation = UUID()
        let token = generation
        queue.async { [self] in
            state.tearDown()
            // Keep lexical roots/parents as well as physical targets. A user's
            // Applications symlink can be retargeted without touching old target.
            let physicalParents = self.roots.map { path in
                let parent = Self.physicalPath((path as NSString).deletingLastPathComponent)
                let name = (path as NSString).lastPathComponent
                return parent == "/" ? "/" + name : parent + "/" + name
            }
            let roots = Array(Set(self.roots + physicalParents + self.roots.map(Self.physicalPath)))
            let box = Context(roots: roots, changed: onChange, reconfigure: { [weak self] in
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    self.start(onChange: onChange, onError: onError)
                }
            }, events: events, decisions: decisions)
            var context = FSEventStreamContext(version: 0,
                info: Unmanaged.passUnretained(box).toOpaque(), retain: { pointer in
                    guard let pointer else { return nil }
                    return UnsafeRawPointer(Unmanaged<Context>.fromOpaque(pointer).retain().toOpaque())
                },
                release: { pointer in
                    if let pointer { Unmanaged<Context>.fromOpaque(pointer).release() }
                }, copyDescription: nil)
            let parents = roots.map { ($0 as NSString).deletingLastPathComponent }.filter { $0 != "/" }
            let watched = Array(Set(roots + parents))
            let created = withExtendedLifetime(box) { FSEventStreamCreate(nil, { _, info, count, paths, flags, _ in
                guard let info else { return }
                let box = Unmanaged<Context>.fromOpaque(info).takeUnretainedValue()
                let paths = unsafeBitCast(paths, to: NSArray.self) as! [String]
                box.events?(paths, Array(UnsafeBufferPointer(start: flags, count: count)))
                var changed = false, reconfigure = false
                for index in 0..<count {
                    // Preserve the raw physical spelling, especially after
                    // deletion: Foundation can transform a nonexistent URL
                    // differently from the existing root. No per-event disk
                    // resolution is needed; setup retained every root alias.
                    let spellings = [paths[index]]
                    let relevant = spellings.contains { ApplicationIndexObservation.matches(path: $0, roots: box.roots) }
                    let lost = flags[index] & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged) != 0
                    box.decisions?("\(paths[index]) [bytes=\(paths[index].utf8.count) events=\(count) paths=\(paths.count) flags=\(flags[index]) lost=\(lost)]", box.roots, relevant)
                    if relevant || lost {
                        let rootChanged = flags[index] & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0
                        let topologyChanged = flags[index] & FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemIsSymlink) != 0
                        reconfigure = reconfigure || rootChanged || (topologyChanged && box.roots.contains(where: { spellings.contains($0) }))
                        changed = true
                    }
                }
                box.decisions?("BATCH callback=\(changed) reconfigure=\(reconfigure)", box.roots, changed)
                if reconfigure { box.reconfigure() }
                if changed { box.changed() }
            }, &context, watched as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.2,
                FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)) }
            guard let created else {
                onError("Automatic application updates unavailable. Use Reindex now to refresh installed apps.")
                return
            }
            state.stream = created
            FSEventStreamSetDispatchQueue(created, queue)
            state.started = FSEventStreamStart(created)
            if !state.started {
                state.tearDown()
                onError("Automatic application updates unavailable. Use Reindex now to refresh installed apps.")
            }
            else {
                // Close the startup race between the first cache scan and
                // asynchronous stream registration without main-thread waiting.
                onChange()
            }
        }
    }
    @MainActor func stop() {
        generation = UUID()
        queue.async { [state] in state.tearDown() }
    }
    deinit {
        // Capturing only stream state avoids resurrecting a deinitializing
        // observer, and preserves serial teardown without main-thread waiting.
        queue.async { [state] in state.tearDown() }
    }
}
