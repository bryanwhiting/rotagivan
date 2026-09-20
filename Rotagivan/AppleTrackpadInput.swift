import AppKit
import Foundation
@preconcurrency import IOKit
import Darwin

/// A read-only source of raw contacts from Apple's built-in and Magic Trackpads.
///
/// MultitouchSupport is a private, undocumented framework. Missing paths and
/// symbols disable this source instead of preventing Rotagivan from launching;
/// the fixed frame layout remains an experimental compatibility assumption and
/// is validated as far as its raw records permit. This class never opens or
/// seizes an HID device, installs an event tap, or suppresses native events.
@MainActor
final class AppleTrackpadInput {
    /// Older experimental builds stored a different three/four-finger schema
    /// inside settings.v1. Preserve it locally before current model decoding
    /// discards unknown keys; do not activate or reinterpret those bindings.
    static func preserveLegacySettings(_ defaults: UserDefaults = .standard) {
        let archiveKey = "input.legacyAppleTrackpadSettings"
        guard defaults.data(forKey: archiveKey) == nil,
              let data = defaults.data(forKey: "settings.v1"),
              let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let legacy = settings["macTrackpad"] as? [String: Any],
              let archive = try? JSONSerialization.data(withJSONObject: legacy, options: [.sortedKeys]) else { return }
        defaults.set(archive, forKey: archiveKey)
    }

    struct DeviceIdentity: Hashable, Sendable {
        let deviceID: UInt64
        let name: String
        let isBuiltIn: Bool
    }

    enum Status: Equatable {
        case stopped
        case unavailable(String)
        case looking
        /// Compatible devices are registered for monitoring. The private API
        /// does not provide a separate acknowledgement for first frame receipt.
        case connected([DeviceIdentity])
    }

    typealias StatusHandler = (Status) -> Void
    typealias ReportHandler = (DeviceIdentity, TrackpadReport, TrackpadDistanceScale, TimeInterval) -> Void

    var onStatus: StatusHandler?
    var onReport: ReportHandler?
    private(set) var status: Status = .stopped

    private static let refreshInterval: TimeInterval = 2
    // Navigator's physical descriptor is 2,048 units across 55 mm. Translating
    // the reverse-engineered Apple millimeter vector to that same logical scale
    // preserves existing gesture tuning and its truthful mm conversion.
    static let unitsPerMillimeter = 2_048.0 / 55.0
    private static let distanceScale = TrackpadDistanceScale(axes: [
        .init(usage: 0x30, logicalMin: 0, logicalMax: 2_048,
              physicalMin: 0, physicalMax: 550, unit: 0x11, unitExponent: 0xE),
        .init(usage: 0x31, logicalMin: 0, logicalMax: 2_048,
              physicalMin: 0, physicalMax: 550, unit: 0x11, unitExponent: 0xE)
    ])!

    private struct Session {
        let device: UnsafeRawPointer
        let identity: DeviceIdentity
        let sink: AppleTrackpadCallbackSink
    }

    private var symbols: AppleMultitouchSymbols?
    private var deviceList: CFArray?
    private var sessions: [Session] = []
    private var refreshTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var running = false
    private var generation: UInt64 = 0

    func start() {
        guard !running else { return }
        guard AppleMultitouchFrame.abiIsSupported else {
            setStatus(.unavailable("Apple trackpad frame ABI is not supported by this build."))
            return
        }
        if symbols == nil {
            switch AppleMultitouchSymbols.load() {
            case .success(let loaded): symbols = loaded
            case .failure(let failure):
                setStatus(.unavailable(failure.message))
                return
            }
        }

        running = true
        // Replacing private-framework handles invalidates any gesture in
        // progress even if the stable device IDs happen to be unchanged.
        generation &+= 1
        setStatus(.looking)
        rebuildDevices(force: true)
        let timer = Timer(timeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildDevices(force: false) }
        }
        refreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildDevices(force: true) }
        }
    }

    /// Re-enumerates the framework's snapshot. This is also safe to call from a
    /// hotplug coordinator; unchanged device IDs do not disturb active streams.
    func refresh() {
        rebuildDevices(force: false)
    }

    func stop() {
        guard running || !sessions.isEmpty else {
            setStatus(.stopped)
            return
        }
        running = false
        generation &+= 1
        refreshTimer?.invalidate()
        refreshTimer = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        tearDownDevices()
        setStatus(.stopped)
    }

    private func rebuildDevices(force: Bool) {
        guard running, let symbols else { return }
        guard let unmanagedList = symbols.createList() else {
            tearDownDevices()
            setStatus(.unavailable("Apple trackpad enumeration is unavailable."))
            return
        }
        let newList = unmanagedList.takeRetainedValue()
        let candidates = Self.trackpads(in: newList, symbols: symbols)
        let currentIDs = Set(sessions.map(\.identity))
        let candidateIDs = Set(candidates.map(\.identity))
        if !force, currentIDs == candidateIDs { return }

        if !sessions.isEmpty { setStatus(.looking) }
        generation &+= 1
        tearDownDevices()
        guard running else { return }
        guard !candidates.isEmpty else {
            setStatus(.looking)
            return
        }

        // The create-rule array owns its borrowed device elements. Keep it
        // alive until every corresponding stream has been stopped.
        deviceList = newList
        for candidate in candidates {
            let sink = AppleTrackpadCallbackSink(owner: self, generation: generation,
                                                  identity: candidate.identity)
            AppleTrackpadCallbackRegistry.shared.install(sink, for: candidate.device)
            symbols.register(candidate.device, AppleMultitouchCallbackBridge.callback)
            _ = symbols.start(candidate.device, 0)
            sessions.append(Session(device: candidate.device, identity: candidate.identity, sink: sink))
        }
        setStatus(.connected(sessions.map(\.identity).sorted { $0.deviceID < $1.deviceID }))
    }

    private func tearDownDevices() {
        guard let symbols else {
            sessions.removeAll()
            deviceList = nil
            return
        }
        // Stop first: unregister-before-stop has raced inside private framework
        // implementations. The registry keeps any already-entered callback sink
        // alive, while the generation gate discards its queued delivery.
        for session in sessions { _ = symbols.stop(session.device) }
        if let unregister = symbols.unregister {
            for session in sessions { unregister(session.device, AppleMultitouchCallbackBridge.callback) }
        }
        for session in sessions {
            AppleTrackpadCallbackRegistry.shared.remove(session.sink, for: session.device)
        }
        sessions.removeAll()
        deviceList = nil
    }

    fileprivate func accept(_ frame: AppleMultitouchFrame, from identity: DeviceIdentity,
                            generation callbackGeneration: UInt64) {
        let deviceKnown = sessions.contains(where: { $0.identity == identity })
        guard Self.callbackIsCurrent(running: running, callbackGeneration: callbackGeneration,
                                     currentGeneration: generation, deviceKnown: deviceKnown) else { return }
        guard let report = Self.report(from: frame) else {
            rejectMalformedFrame(generation: callbackGeneration)
            return
        }
        onReport?(identity, report, Self.distanceScale, frame.receivedAt)
    }

    static func callbackIsCurrent(running: Bool, callbackGeneration: UInt64,
                                  currentGeneration: UInt64, deviceKnown: Bool) -> Bool {
        running && callbackGeneration == currentGeneration && deviceKnown
    }

    static func report(from frame: AppleMultitouchFrame) -> TrackpadReport? {
        let contactIDs = frame.contacts.map { UInt8(truncatingIfNeeded: $0.identifier) }
        guard Set(contactIDs).count == contactIDs.count else { return nil }
        let units = Self.unitsPerMillimeter
        let contacts = frame.contacts.map { contact in
            let millimetersArePlausible = contact.millimetersX.isFinite && contact.millimetersY.isFinite &&
                abs(contact.millimetersX) < 1_000 && abs(contact.millimetersY) < 1_000
            let normalizedArePlausible = contact.normalizedX.isFinite && contact.normalizedY.isFinite &&
                (-0.1...1.1).contains(contact.normalizedX) && (-0.1...1.1).contains(contact.normalizedY)
            // Apple's Y origin is at the near edge of the surface, opposite the
            // HID report convention used by TrackpadReport, so invert its delta.
            let x = millimetersArePlausible ? contact.millimetersX * units : contact.normalizedX * 2_048
            let y = millimetersArePlausible ? -contact.millimetersY * units : -contact.normalizedY * 2_048
            let touching = contact.state == 3 || contact.state == 4
            return FingerContact(id: UInt8(truncatingIfNeeded: contact.identifier), x: x, y: y,
                touching: touching, confident: millimetersArePlausible && normalizedArePlausible)
        }
        return TrackpadReport(contacts: contacts, buttonDown: false,
                              scanTime: UInt16(truncatingIfNeeded: frame.number))
    }

    fileprivate func rejectMalformedFrame(generation callbackGeneration: UInt64) {
        guard running, callbackGeneration == generation else { return }
        running = false
        generation &+= 1
        refreshTimer?.invalidate()
        refreshTimer = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        tearDownDevices()
        setStatus(.unavailable("Apple trackpad frame data is incompatible with this macOS version."))
    }

    private func setStatus(_ newStatus: Status) {
        guard status != newStatus else { return }
        status = newStatus
        onStatus?(newStatus)
    }

    private struct Candidate {
        let device: UnsafeRawPointer
        let identity: DeviceIdentity
    }

    private static func trackpads(in list: CFArray, symbols: AppleMultitouchSymbols) -> [Candidate] {
        var resultByID: [UInt64: Candidate] = [:]
        for index in 0..<CFArrayGetCount(list) {
            guard let device = CFArrayGetValueAtIndex(list, index) else { continue }
            var deviceID: UInt64 = 0
            guard symbols.getDeviceID(device, &deviceID) == 0, deviceID != 0 else { continue }

            var sensorRows: Int32 = 0
            var sensorColumns: Int32 = 0
            guard symbols.getSensorDimensions(device, &sensorRows, &sensorColumns) == 0,
                  min(sensorRows, sensorColumns) >= 10 else { continue }
            var surfaceWidth: Int32 = 0
            var surfaceHeight: Int32 = 0
            guard symbols.getSurfaceDimensions(device, &surfaceWidth, &surfaceHeight) == 0,
                  surfaceWidth > surfaceHeight, surfaceHeight > 0 else { continue }

            let isBuiltIn = symbols.isBuiltIn(device)
            var registryDescription = symbols.getService.map { registryIdentity(for: $0(device)) } ?? ""
            if registryDescription.isEmpty {
                registryDescription = registryIdentity(forMultitouchID: deviceID)
            }
            let description = registryDescription.lowercased()
            guard !description.contains("mouse"), !description.contains("touchbar"),
                  !description.contains("touch bar") else { continue }
            let positivelyNamedTrackpad = description.contains("trackpad")
            // External means either Magic Trackpad or Magic Mouse. Require a
            // positive trackpad identity for external hardware; built-in devices
            // may use generic service names, so admit only the strict geometry
            // that already excludes Touch Bar and Magic Mouse surfaces.
            guard positivelyNamedTrackpad || isBuiltIn else { continue }

            let identity = DeviceIdentity(deviceID: deviceID,
                name: isBuiltIn ? "Built-in Trackpad" : "Magic Trackpad", isBuiltIn: isBuiltIn)
            resultByID[deviceID] = Candidate(device: device, identity: identity)
        }
        return resultByID.values.sorted { $0.identity.deviceID < $1.identity.deviceID }
    }

    private static func registryIdentity(for service: io_service_t) -> String {
        guard service != 0 else { return "" }
        var descriptions: [String] = []
        var entry = service
        var ownsEntry = false
        defer { if ownsEntry { IOObjectRelease(entry) } }
        for _ in 0..<10 {
            if let className = IOObjectCopyClass(entry)?.takeRetainedValue() as String? {
                descriptions.append(className)
            }
            var properties: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(entry, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dictionary = properties?.takeRetainedValue() as? [String: Any] {
                for key in ["Product", "Product Name", "USB Product Name", kIOHIDProductKey as String] {
                    if let value = dictionary[key] as? String { descriptions.append(value) }
                }
            }
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS else { break }
            if ownsEntry { IOObjectRelease(entry) }
            entry = parent
            ownsEntry = true
        }
        return descriptions.joined(separator: " ")
    }

    private static func registryIdentity(forMultitouchID deviceID: UInt64) -> String {
        guard let matching = IOServiceMatching("AppleMultitouchDevice") else { return "" }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return "" }
        defer { IOObjectRelease(iterator) }
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { return "" }
            defer { IOObjectRelease(service) }
            guard let property = IORegistryEntryCreateCFProperty(service, "Multitouch ID" as CFString,
                                                                  kCFAllocatorDefault, 0)?.takeRetainedValue(),
                  let number = property as? NSNumber, number.uint64Value == deviceID else { continue }
            return registryIdentity(for: service)
        }
    }
}

// MARK: - Private MultitouchSupport ABI

private typealias AppleMultitouchCallback = @convention(c) (
    UnsafeRawPointer?, UnsafeRawPointer?, Int32, Double, Int32
) -> Int32

struct AppleMultitouchContact: Sendable {
    let identifier: Int32
    let state: Int32
    let normalizedX: Double
    let normalizedY: Double
    let millimetersX: Double
    let millimetersY: Double
}

struct AppleMultitouchFrame: Sendable {
    static let contactStride = 96
    static let maximumContacts = 32
    static let abiIsSupported = MemoryLayout<Double>.size == 8 && MemoryLayout<Float>.size == 4 &&
        MemoryLayout<Int32>.size == 4 && MemoryLayout<UnsafeRawPointer>.size == 8

    let contacts: [AppleMultitouchContact]
    let number: Int32
    let receivedAt: TimeInterval

    static func copy(from pointer: UnsafeRawPointer?, count: Int32, number: Int32) -> Self? {
        guard count >= 0, count <= maximumContacts else { return nil }
        guard count == 0 || pointer != nil else { return nil }
        var contacts: [AppleMultitouchContact] = []
        contacts.reserveCapacity(Int(count))
        if let pointer {
            for index in 0..<Int(count) {
                let record = pointer.advanced(by: index * contactStride)
                let state = record.loadUnaligned(fromByteOffset: 20, as: Int32.self)
                guard (0...7).contains(state) else { return nil }
                let normalizedX = Double(record.loadUnaligned(fromByteOffset: 32, as: Float.self))
                let normalizedY = Double(record.loadUnaligned(fromByteOffset: 36, as: Float.self))
                let millimetersX = Double(record.loadUnaligned(fromByteOffset: 68, as: Float.self))
                let millimetersY = Double(record.loadUnaligned(fromByteOffset: 72, as: Float.self))
                contacts.append(AppleMultitouchContact(
                    identifier: record.loadUnaligned(fromByteOffset: 16, as: Int32.self), state: state,
                    normalizedX: normalizedX, normalizedY: normalizedY,
                    millimetersX: millimetersX, millimetersY: millimetersY))
            }
        }
        return Self(contacts: contacts, number: number,
                    receivedAt: ProcessInfo.processInfo.systemUptime)
    }
}

private final class AppleTrackpadCallbackSink: @unchecked Sendable {
    weak var owner: AppleTrackpadInput?
    let generation: UInt64
    let identity: AppleTrackpadInput.DeviceIdentity

    @MainActor
    init(owner: AppleTrackpadInput, generation: UInt64, identity: AppleTrackpadInput.DeviceIdentity) {
        self.owner = owner
        self.generation = generation
        self.identity = identity
    }

    @MainActor
    func deliver(_ frame: AppleMultitouchFrame) {
        owner?.accept(frame, from: identity, generation: generation)
    }

    @MainActor
    func rejectMalformedFrame() {
        owner?.rejectMalformedFrame(generation: generation)
    }
}

private final class AppleTrackpadCallbackRegistry: @unchecked Sendable {
    static let shared = AppleTrackpadCallbackRegistry()
    private let lock = NSLock()
    private var sinks: [UInt: AppleTrackpadCallbackSink] = [:]

    func install(_ sink: AppleTrackpadCallbackSink, for device: UnsafeRawPointer) {
        lock.lock()
        sinks[UInt(bitPattern: device)] = sink
        lock.unlock()
    }

    func sink(for device: UnsafeRawPointer) -> AppleTrackpadCallbackSink? {
        lock.lock()
        let sink = sinks[UInt(bitPattern: device)]
        lock.unlock()
        return sink
    }

    func remove(_ sink: AppleTrackpadCallbackSink, for device: UnsafeRawPointer) {
        lock.lock()
        let key = UInt(bitPattern: device)
        if sinks[key] === sink { sinks.removeValue(forKey: key) }
        lock.unlock()
    }
}

private enum AppleMultitouchCallbackBridge {
    static let callback: AppleMultitouchCallback = { device, contacts, count, _, frameNumber in
        guard let device, let sink = AppleTrackpadCallbackRegistry.shared.sink(for: device) else { return 0 }
        guard let frame = AppleMultitouchFrame.copy(from: contacts, count: count, number: frameNumber) else {
            DispatchQueue.main.async { sink.rejectMalformedFrame() }
            return 0
        }
        // Only immutable scalar values cross the callback boundary; neither the
        // device pointer nor the callback-scoped contact pointer is retained.
        DispatchQueue.main.async { sink.deliver(frame) }
        return 0
    }
}

private final class AppleMultitouchSymbols {
    typealias CreateList = @convention(c) () -> Unmanaged<CFArray>?
    typealias Register = @convention(c) (UnsafeRawPointer, AppleMultitouchCallback) -> Void
    typealias Unregister = @convention(c) (UnsafeRawPointer, AppleMultitouchCallback) -> Void
    typealias Start = @convention(c) (UnsafeRawPointer, Int32) -> Int32
    typealias Stop = @convention(c) (UnsafeRawPointer) -> Int32
    typealias GetDimensions = @convention(c) (UnsafeRawPointer, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>) -> Int32
    typealias GetDeviceID = @convention(c) (UnsafeRawPointer, UnsafeMutablePointer<UInt64>) -> Int32
    typealias IsBuiltIn = @convention(c) (UnsafeRawPointer) -> Bool
    typealias GetService = @convention(c) (UnsafeRawPointer) -> io_service_t

    let createList: CreateList
    let register: Register
    let unregister: Unregister?
    let start: Start
    let stop: Stop
    let getSensorDimensions: GetDimensions
    let getSurfaceDimensions: GetDimensions
    let getDeviceID: GetDeviceID
    let isBuiltIn: IsBuiltIn
    let getService: GetService?

    private init(handle: UnsafeMutableRawPointer) throws {
        func required<T>(_ name: String, _: T.Type) throws -> T {
            guard let symbol = dlsym(handle, name) else { throw LoadError.missingSymbol(name) }
            return unsafeBitCast(symbol, to: T.self)
        }
        func optional<T>(_ name: String, _: T.Type) -> T? {
            guard let symbol = dlsym(handle, name) else { return nil }
            return unsafeBitCast(symbol, to: T.self)
        }
        createList = try required("MTDeviceCreateList", CreateList.self)
        register = try required("MTRegisterContactFrameCallback", Register.self)
        unregister = optional("MTUnregisterContactFrameCallback", Unregister.self)
        start = try required("MTDeviceStart", Start.self)
        stop = try required("MTDeviceStop", Stop.self)
        getSensorDimensions = try required("MTDeviceGetSensorDimensions", GetDimensions.self)
        getSurfaceDimensions = try required("MTDeviceGetSensorSurfaceDimensions", GetDimensions.self)
        getDeviceID = try required("MTDeviceGetDeviceID", GetDeviceID.self)
        isBuiltIn = try required("MTDeviceIsBuiltIn", IsBuiltIn.self)
        getService = optional("MTDeviceGetService", GetService.self)
        // Deliberately do not dlclose: a private-framework callback may already
        // be in flight when stop returns, so code addresses remain valid for the
        // remainder of the process.
    }

    enum LoadError: Error {
        case missingSymbol(String)
    }

    struct LoadFailure: Error {
        let message: String
    }

    static func load() -> Result<AppleMultitouchSymbols, LoadFailure> {
        let paths = [
            "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport",
            "/System/Library/PrivateFrameworks/MultitouchSupport.framework/Versions/A/MultitouchSupport",
            "/System/Library/PrivateFrameworks/MultitouchSupportPrivate.framework/MultitouchSupportPrivate",
            "/System/Library/PrivateFrameworks/MultitouchSupportPrivate.framework/Versions/A/MultitouchSupportPrivate"
        ]
        for path in paths {
            guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else { continue }
            do { return .success(try AppleMultitouchSymbols(handle: handle)) }
            catch LoadError.missingSymbol(let name) {
                return .failure(LoadFailure(message: "Apple trackpad support is unavailable (missing \(name))."))
            } catch {
                return .failure(LoadFailure(message: "Apple trackpad support is unavailable on this macOS version."))
            }
        }
        return .failure(LoadFailure(message: "Apple's private trackpad framework is unavailable on this macOS version."))
    }
}
