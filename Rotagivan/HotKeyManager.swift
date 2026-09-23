import Carbon
import AppKit
import Foundation
import Combine

extension Notification.Name {
    static let shortcutRecordingStarted = Notification.Name("Rotagivan.shortcutRecordingStarted")
    static let shortcutRecordingStopped = Notification.Name("Rotagivan.shortcutRecordingStopped")
}

@MainActor
final class ShortcutSettings: ObservableObject {
    static let shared = ShortcutSettings()
    @Published var normal: ProfileShortcut { didSet { save() } }
    @Published var precision: ProfileShortcut { didSet { save() } }
    @Published var error: String?
    @Published var actions: [ProfileShortcut] { didSet { save() } }
    @Published var additional: [UInt32: ProfileShortcut] { didSet { save() } }
    @Published var profileActions: [UInt32: [ProfileShortcut]] { didSet { save() } }
    @Published var dragShortcut: ProfileShortcut { didSet { save() } }
    private var replacingConfiguration = false

    func replaceConfiguration(normal: ProfileShortcut, precision: ProfileShortcut,
                              actions: [ProfileShortcut], additional: [UInt32: ProfileShortcut],
                              profileActions: [UInt32: [ProfileShortcut]], holdToActivate: Bool,
                              dragShortcut: ProfileShortcut? = nil, defaultID: UInt32 = 1) {
        replacingConfiguration = true
        self.normal = normal
        self.precision = precision
        self.actions = actions
        self.additional = additional
        self.profileActions = profileActions
        self.dragShortcut = dragShortcut ?? Self.legacyDragShortcut(
            defaultID: defaultID, actions: actions, profileActions: profileActions)
        UserDefaults.standard.set(holdToActivate, forKey: "shortcut.hold")
        replacingConfiguration = false
        save()
    }

    func actions(for id: UInt32) -> [ProfileShortcut] {
        guard let saved = profileActions[id], saved.count == 3 else { return actions }
        return saved
    }

    private static func legacyDragShortcut(defaultID: UInt32, actions: [ProfileShortcut],
                                           profileActions: [UInt32: [ProfileShortcut]]) -> ProfileShortcut {
        let legacy = profileActions[defaultID]?.count == 3 ? profileActions[defaultID]! : actions
        return legacy.indices.contains(2) ? legacy[2] : ProfileShortcut(keyCode: 90)
    }

    func disableActivation(for id: UInt32) {
        if id == 1 { normal.enabled = false }
        else if id == 2 { precision.enabled = false }
        else if additional[id] != nil { additional[id]?.enabled = false }
    }
    static let keys: [(String, UInt32)] = [("F1",122),("F2",120),("F3",99),("F4",118),("F5",96),("F6",97),("F7",98),("F8",100),("F9",101),("F10",109),("F11",103),("F12",111),("F13",105),("F14",107),("F15",113),("F16",106),("F17",64),("F18",79),("F19",80),("F20",90)] + Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ").enumerated().map { index, letter in
        (String(letter), [UInt32(0),11,8,2,14,3,5,4,34,38,40,37,46,45,31,35,12,15,1,17,32,9,13,7,16,6][index])
    }
    private init() {
        func read(_ key: String) -> ProfileShortcut? {
            UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(ProfileShortcut.self, from: $0) }
        }
        normal = read("shortcut.normal") ?? ProfileShortcut()
        let loadedProfileActions = UserDefaults.standard.data(forKey: "shortcut.profileActions").flatMap { try? JSONDecoder().decode([UInt32: [ProfileShortcut]].self, from: $0) } ?? [:]
        profileActions = loadedProfileActions
        additional = UserDefaults.standard.data(forKey: "shortcut.additional").flatMap { try? JSONDecoder().decode([UInt32: ProfileShortcut].self, from: $0) } ?? [:]
        let loadedActions = (3...5).map { read("shortcut.action.\($0)") ?? ProfileShortcut(keyCode: UInt32($0 == 3 ? 79 : $0 == 4 ? 80 : 90)) }
        actions = loadedActions
        let defaultID = UserDefaults.standard.data(forKey: "settings.v1")
            .flatMap { try? JSONDecoder().decode(StoredSettings.self, from: $0) }?.resolvedDefaultProfileID ?? 1
        dragShortcut = read("shortcut.drag") ?? Self.legacyDragShortcut(
            defaultID: defaultID, actions: loadedActions, profileActions: loadedProfileActions)
        precision = read("shortcut.precision") ?? ProfileShortcut(enabled: true)
        let legacyHold = UserDefaults.standard.object(forKey: "shortcut.hold") as? Bool ?? true
        if normal.holdToActivate == nil { normal.holdToActivate = legacyHold }
        if precision.holdToActivate == nil { precision.holdToActivate = legacyHold }
    }
    private func save() {
        guard !replacingConfiguration else { return }
        for (index, action) in actions.enumerated() { UserDefaults.standard.set(try? JSONEncoder().encode(action), forKey: "shortcut.action.\(index + 3)") }
        UserDefaults.standard.set(try? JSONEncoder().encode(normal), forKey: "shortcut.normal")
        UserDefaults.standard.set(try? JSONEncoder().encode(precision), forKey: "shortcut.precision")
        UserDefaults.standard.set(try? JSONEncoder().encode(additional), forKey: "shortcut.additional")
        UserDefaults.standard.set(try? JSONEncoder().encode(profileActions), forKey: "shortcut.profileActions")
        UserDefaults.standard.set(try? JSONEncoder().encode(dragShortcut), forKey: "shortcut.drag")
    }
}

// Holds temporarily override the latched profile; toggles survive key release.
struct ProfileActivationState {
    private var latched: UInt32
    private var previous: UInt32
    private let defaultID: UInt32
    init(defaultID: UInt32 = 1) {
        self.defaultID = defaultID
        latched = defaultID
        previous = defaultID
    }
    private var held: [UInt32] = []
    private var pressed = Set<UInt32>()
    var active: UInt32 { held.last ?? latched }

    mutating func releaseHolds() {
        held.removeAll()
        pressed.removeAll()
    }

    mutating func handle(id: UInt32, down: Bool, hold: Bool) -> UInt32 {
        if down {
            guard pressed.insert(id).inserted else { return active }
            if hold { held.append(id) }
            else {
                if latched == id {
                    let target = previous == id ? defaultID : previous
                    previous = latched
                    latched = target
                } else {
                    previous = latched
                    latched = id
                }
            }
        } else {
            pressed.remove(id)
            held.removeAll { $0 == id }
        }
        return active
    }
}

@MainActor
final class HotKeyManager {
    var onProfileChanged: ((UInt32) -> Void)?
    var profileName: ((UInt32) -> String?)?
    var onAction: ((UInt32, Bool) -> Void)?
    var onExplorerHold: ((Bool) -> Void)?
    var onHUDLayer: ((UUID) -> Void)?
    var onNamedHotkey: ((String) -> Void)?
    var onBindingAction: ((BindingAction) -> Void)?
    /// Gives a visible HUD first refusal on physical Carbon hotkeys.
    var onHUDKey: ((UInt16, UInt64, Bool) -> Bool)?
    private var registeredKeys: [String: (UInt16, UInt64)] = [:]
    private var profileKeyIdentities = Set<String>()
    private var interceptedKeys: [String: (UInt16, UInt64)] = [:]
    private var cancelledReleases = Set<String>()
    private func hotkeyIdentity(_ signature: OSType, _ id: UInt32) -> String { "\(signature):\(id)" }
    private func remember(_ signature: OSType, _ id: UInt32, _ key: UInt32, _ carbon: UInt32) {
        let cocoa = UInt64((carbon & 4096 != 0 ? 1 << 18 : 0) |
            (carbon & 2048 != 0 ? 1 << 19 : 0) |
            (carbon & 512 != 0 ? 1 << 17 : 0) |
            (carbon & 256 != 0 ? 1 << 20 : 0))
        registeredKeys[hotkeyIdentity(signature, id)] = (UInt16(truncatingIfNeeded: key), cocoa)
    }
    @discardableResult func routeHUDHotkey(signature: OSType, id: UInt32, down: Bool,
                                           key override: (UInt16, UInt64)? = nil) -> Bool {
        let identity = hotkeyIdentity(signature, id)
        guard !recording else { return false }
        if !down, cancelledReleases.remove(identity) != nil { return true }
        if down { cancelledReleases.remove(identity) }
        if let captured = interceptedKeys[identity] {
            if !down {
                interceptedKeys.removeValue(forKey: identity)
                _ = onHUDKey?(captured.0, captured.1, false)
            }
            return true
        }
        guard down, let key = override ?? registeredKeys[identity],
              onHUDKey?(key.0, key.1, true) == true else { return false }
        interceptedKeys[identity] = key
        return true
    }
    /// End HUD-local held layers before Carbon registrations change identity.
    func cancelHUDCaptures() {
        let captured = interceptedKeys
        interceptedKeys.removeAll()
        for (identity, key) in captured {
            cancelledReleases.insert(identity)
            _ = onHUDKey?(key.0, key.1, false)
        }
    }
    func beginShortcutRecording() {
        recording = true
        cancelHUDCaptures()
    }
    private var actionBindings: [ActionBinding] = []
    private var bindingActions: [UInt32: BindingAction] = [:]
    private var bindingPressed = Set<UInt32>()
    func configureActionBindings(_ bindings: [ActionBinding]) {
        guard bindings != actionBindings else { return }
        actionBindings = bindings
        if handler != nil { registerActions() }
    }
    private var namedHotkeys: [NamedHotkey] = []
    private var namedHotkeyIDs: [UInt32: String] = [:]
    private var namedHotkeyPressed = Set<UInt32>()
    func configureNamedHotkeys(_ entries: [NamedHotkey]) {
        guard entries != namedHotkeys else { return }
        namedHotkeys = entries
        if handler != nil { registerActions() }
    }
    private var hudLayers: [ExplorerHoldLayer] = []
    private var hudLaunchIDs: [UInt32: UUID] = [:]
    private var hudPressed = Set<UInt32>()
    func configureHUDLayers(_ layers: [ExplorerHoldLayer]) {
        guard layers != hudLayers else { return }
        hudLayers = layers
        if handler != nil { registerActions() }
    }
    private var explorerShortcut: RecordedShortcut?
    func configureExplorer(_ shortcut: RecordedShortcut?) {
        guard shortcut != explorerShortcut else { return }
        explorerShortcut = shortcut
        if handler != nil { registerActions() }
    }
    private var refs: [EventHotKeyRef?] = []
    private var handler: EventHandlerRef?
    private var pressed = Set<UInt32>()
    private var observation: AnyCancellable?
    private var actionObservation: AnyCancellable?
    private var actionRefs: [EventHotKeyRef?] = []
    private var defaultActions: [ProfileShortcut] = []
    private var savedActions: [UInt32: [ProfileShortcut]] = [:]
    private var profileDragShortcut = ProfileShortcut(keyCode: 90)
    private var customTapProfiles = Set<UInt32>()
    private var defaultProfileID: UInt32 = 1
    private var availableProfileIDs: Set<UInt32>?

    func configureProfiles(defaultID: UInt32, customTaps: Set<UInt32>, availableIDs: Set<UInt32>? = nil) {
        let changed = defaultProfileID != defaultID || availableProfileIDs != availableIDs
        defaultProfileID = defaultID
        availableProfileIDs = availableIDs
        if changed {
            // Imports suspend registrations while replacing multiple stores.
            // Reset the activation baseline even while registration is paused.
            activation = ProfileActivationState(defaultID: defaultID)
            customTapProfiles = customTaps
            let settings = ShortcutSettings.shared
            if handler != nil { register(normal: settings.normal, precision: settings.precision, additional: settings.additional) }
            else { activation = ProfileActivationState(defaultID: defaultID) }
        } else { setCustomTapProfiles(customTaps) }
    }

    func setCustomTapProfiles(_ profiles: Set<UInt32>) {
        guard profiles != customTapProfiles else { return }
        customTapProfiles = profiles
        if handler != nil { registerActions() }
    }

    static func resolvedActions(for id: UInt32, defaults: [ProfileShortcut], saved: [UInt32: [ProfileShortcut]], customTapProfiles: Set<UInt32>, defaultID: UInt32 = 1, dragShortcut: ProfileShortcut? = nil) -> [ProfileShortcut] {
        let own = saved[id]?.count == 3 ? saved[id]! : defaults
        let primary = saved[defaultID]?.count == 3 ? saved[defaultID]! : defaults
        guard own.count == 3, primary.count == 3 else { return own }
        let taps = id != defaultID && !customTapProfiles.contains(id) ? [primary[0], primary[1]] : [own[0], own[1]]
        return taps + [dragShortcut ?? primary[2]]
    }
    private var profileCombinations = Set<String>()
    private var profileError: String?
    private var recording = false
    private var recordingObservers = Set<AnyCancellable>()
    private var activation = ProfileActivationState()
    private var profileHolds: [UInt32: Bool] = [:]

    func install() {
        guard handler == nil else { return }
        NotificationCenter.default.publisher(for: .configurationProfileChanged).sink { [weak self] notification in
            guard let self, let id = notification.object as? UInt32 else { return }
            // Layer IDs are reused across top-level profiles. Even when the
            // default ID is unchanged, a latched layer from the old profile
            // must not leak into the newly selected configuration.
            self.defaultProfileID = id
            self.activation = ProfileActivationState(defaultID: id)
            self.onProfileChanged?(id)
            if !self.recording {
                let keys = ShortcutSettings.shared
                self.register(normal: keys.normal, precision: keys.precision, additional: keys.additional)
            }
        }.store(in: &recordingObservers)
        NotificationCenter.default.publisher(for: .shortcutRecordingStarted).sink { [weak self] _ in
            guard let self else { return }
            self.beginShortcutRecording()
            self.onExplorerHold?(false)
            self.onAction?(5, false)
            (self.refs + self.actionRefs).compactMap { $0 }.forEach { UnregisterEventHotKey($0) }
            self.refs.removeAll()
            self.actionRefs.removeAll()
            self.registeredKeys.removeAll()
            self.profileKeyIdentities.removeAll()
            self.pressed.removeAll()
            self.activation.releaseHolds()
            self.onProfileChanged?(self.activation.active)
        }.store(in: &recordingObservers)
        NotificationCenter.default.publisher(for: .shortcutRecordingStopped).sink { [weak self] _ in
            guard let self else { return }
            self.recording = false
            let shortcuts = ShortcutSettings.shared
            self.register(normal: shortcuts.normal, precision: shortcuts.precision, additional: shortcuts.additional, resetActivation: false)
        }.store(in: &recordingObservers)
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let callback: EventHandlerUPP = { _, event, context in
            guard let event, let context else { return noErr }
            var id = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard result == noErr else { return result }
            let owner = Unmanaged<HotKeyManager>.fromOpaque(context).takeUnretainedValue()
            let down = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            DispatchQueue.main.async {
                if owner.routeHUDHotkey(signature: id.signature, id: id.id, down: down) { return }
                if id.signature == HotKeyManager.fourCC("RHUD") {
                    if down, !owner.recording, owner.hudPressed.insert(id.id).inserted,
                       let layer = owner.hudLaunchIDs[id.id] { owner.onHUDLayer?(layer) }
                    else if !down { owner.hudPressed.remove(id.id) }
                } else if id.signature == HotKeyManager.fourCC("RMAC") {
                    if down, !owner.recording, owner.namedHotkeyPressed.insert(id.id).inserted,
                       let action = owner.namedHotkeyIDs[id.id] { owner.onNamedHotkey?(action) }
                    else if !down { owner.namedHotkeyPressed.remove(id.id) }
                } else if id.signature == HotKeyManager.fourCC("RBND") {
                    if down, !owner.recording, owner.bindingPressed.insert(id.id).inserted,
                       let action = owner.bindingActions[id.id] { owner.onBindingAction?(action) }
                    else if !down { owner.bindingPressed.remove(id.id) }
                } else { owner.handle(id: id.id, down: down) }
            }
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), callback, eventTypes.count, &eventTypes, Unmanaged.passUnretained(self).toOpaque(), &handler)

        observation = ShortcutSettings.shared.$normal.combineLatest(ShortcutSettings.shared.$precision, ShortcutSettings.shared.$additional)
            .sink { [weak self] normal, precision, additional in
                self?.register(normal: normal, precision: precision, additional: additional)
            }
        actionObservation = ShortcutSettings.shared.$actions.combineLatest(
            ShortcutSettings.shared.$profileActions, ShortcutSettings.shared.$dragShortcut)
            .sink { [weak self] actions, saved, dragShortcut in
                self?.defaultActions = actions
                self?.savedActions = saved
                self?.profileDragShortcut = dragShortcut
                self?.registerActions()
            }
    }

    private func register(normal: ProfileShortcut, precision: ProfileShortcut, additional: [UInt32: ProfileShortcut], resetActivation: Bool = true) {
        guard !recording else { return }
        cancelHUDCaptures()
        onAction?(5, false)
        actionRefs.compactMap { $0 }.forEach { UnregisterEventHotKey($0) }
        actionRefs.removeAll()
        refs.compactMap { $0 }.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        registeredKeys.removeAll()
        profileKeyIdentities.removeAll()
        pressed.removeAll()
        if resetActivation { activation = ProfileActivationState(defaultID: defaultProfileID) }
        profileHolds = [1: normal.holdToActivate ?? true, 2: precision.holdToActivate ?? true]
        for (id, shortcut) in additional { profileHolds[id] = shortcut.holdToActivate ?? true }
        profileHolds.removeValue(forKey: defaultProfileID)
        onProfileChanged?(activation.active)
        ShortcutSettings.shared.error = nil
        let configured: [(id: UInt32, name: String, shortcut: ProfileShortcut)] =
            ([(1, "Normal", normal), (2, "Precision", precision)] +
            additional.sorted { $0.key < $1.key }.map { ($0.key, "Layer \($0.key - 97)", $0.value) })
            .filter { availableProfileIDs?.contains($0.id) ?? true }
        let all = configured.filter { $0.id != defaultProfileID }
        let enabled = all.map(\.shortcut).filter(\.enabled)
        profileCombinations = Set(enabled.map { "\($0.keyCode):\($0.modifiers)" })
        defer {
            profileError = ShortcutSettings.shared.error
            registerActions()
        }
        if Set(enabled.map { "\($0.keyCode):\($0.modifiers)" }).count != enabled.count {
            ShortcutSettings.shared.error = "Choose a unique shortcut for each layer and mouse action."
            return
        }
        for (id, name, shortcut) in all where shortcut.enabled {
            if shortcut.keyCode < 64 && shortcut.modifiers == 0 {
                ShortcutSettings.shared.error = "Letter shortcuts need at least one modifier."
                continue
            }
            var ref: EventHotKeyRef?
            let result = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, EventHotKeyID(signature: Self.fourCC("NZCL"), id: id), GetApplicationEventTarget(), 0, &ref)
            if result != noErr {
                let displayName = profileHolds[id] != nil ? (profileName?(id) ?? name) : name
                ShortcutSettings.shared.error = "\(displayName) shortcut is unavailable. Choose another combination."
            }
            refs.append(ref)
            if result == noErr {
                remember(Self.fourCC("NZCL"), id, shortcut.keyCode, shortcut.modifiers)
                profileKeyIdentities.insert(hotkeyIdentity(Self.fourCC("NZCL"), id))
            }
        }
    }

    private func registerActions() {
        guard !recording else { return }
        cancelHUDCaptures()
        onExplorerHold?(false)
        // Releasing before replacing registrations prevents a stuck drag on profile changes.
        onAction?(5, false)
        pressed.removeAll()
        actionRefs.compactMap { $0 }.forEach { UnregisterEventHotKey($0) }
        actionRefs.removeAll()
        registeredKeys = registeredKeys.filter { profileKeyIdentities.contains($0.key) }
        ShortcutSettings.shared.error = profileError
        hudLaunchIDs.removeAll()
        hudPressed.removeAll()
        namedHotkeyIDs.removeAll()
        namedHotkeyPressed.removeAll()
        bindingActions.removeAll()
        bindingPressed.removeAll()
        let actions = Self.resolvedActions(for: activation.active, defaults: defaultActions, saved: savedActions,
            customTapProfiles: customTapProfiles, defaultID: defaultProfileID, dragShortcut: profileDragShortcut)
        var used = profileCombinations
        for (index, shortcut) in actions.prefix(3).enumerated() where shortcut.enabled {
            let name = ["Click at cursor", "Double-click at cursor", "Keyboard drag"][index]
            let combination = "\(shortcut.keyCode):\(shortcut.modifiers)"
            guard used.insert(combination).inserted else {
                ShortcutSettings.shared.error = "\(name) conflicts with another shortcut in this layer."
                continue
            }
            guard shortcut.keyCode >= 64 || shortcut.modifiers != 0 else {
                ShortcutSettings.shared.error = "Letter shortcuts need at least one modifier."
                continue
            }
            var ref: EventHotKeyRef?
            let result = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, EventHotKeyID(signature: Self.fourCC("NZCL"), id: UInt32(index + 3)), GetApplicationEventTarget(), 0, &ref)
            if result != noErr { ShortcutSettings.shared.error = "\(name) shortcut is unavailable. Choose another combination." }
            actionRefs.append(ref)
            if result == noErr { remember(Self.fourCC("NZCL"), UInt32(index + 3), shortcut.keyCode, shortcut.modifiers) }
        }
        for (index, layer) in hudLayers.enumerated() where layer.isAvailable(in: NSWorkspace.shared.frontmostApplication?.bundleIdentifier) {
            guard let shortcut = layer.launchShortcut, shortcut.isPhysicalShortcut else { continue }
            let carbonFlags = UInt32((shortcut.modifiers & (1 << 18) != 0 ? 4096 : 0) |
                (shortcut.modifiers & (1 << 19) != 0 ? 2048 : 0) |
                (shortcut.modifiers & (1 << 17) != 0 ? 512 : 0) |
                (shortcut.modifiers & (1 << 20) != 0 ? 256 : 0))
            let profileKey = ProfileShortcut(keyCode: UInt32(shortcut.keyCode), modifiers: carbonFlags, enabled: true)
            guard shortcut.keyCode != 53, shortcut.keyCode >= 64 || profileKey.modifiers != 0,
                  used.insert("\(profileKey.keyCode):\(profileKey.modifiers)").inserted else {
                ShortcutSettings.shared.error = "HUD layer \(layer.name) has an invalid or conflicting launch key."; continue
            }
            let id = UInt32(index)
            var ref: EventHotKeyRef?
            let result = RegisterEventHotKey(profileKey.keyCode, profileKey.modifiers, EventHotKeyID(signature: Self.fourCC("RHUD"), id: id), GetApplicationEventTarget(), 0, &ref)
            if result == noErr { hudLaunchIDs[id] = layer.id; actionRefs.append(ref); remember(Self.fourCC("RHUD"), id, profileKey.keyCode, profileKey.modifiers) }
            else { ShortcutSettings.shared.error = "HUD layer \(layer.name) launch key is unavailable." }
        }
        if let shortcut = explorerShortcut {
            let modifiers = UInt32((shortcut.modifiers & (1 << 18) != 0 ? 4096 : 0) |
                (shortcut.modifiers & (1 << 19) != 0 ? 2048 : 0) |
                (shortcut.modifiers & (1 << 17) != 0 ? 512 : 0) |
                (shortcut.modifiers & (1 << 20) != 0 ? 256 : 0))
            guard used.insert("\(shortcut.keyCode):\(modifiers)").inserted else {
                ShortcutSettings.shared.error = "App Explorer conflicts with a layer or mouse shortcut."; return
            }
            guard shortcut.keyCode >= 64 || modifiers != 0 else {
                ShortcutSettings.shared.error = "App Explorer letter shortcuts need a modifier."; return
            }
            var ref: EventHotKeyRef?
            let result = RegisterEventHotKey(UInt32(shortcut.keyCode), modifiers, EventHotKeyID(signature: Self.fourCC("NZCL"), id: 6), GetApplicationEventTarget(), 0, &ref)
            if result != noErr { ShortcutSettings.shared.error = "App Explorer shortcut is unavailable. Choose another combination." }
            actionRefs.append(ref)
            if result == noErr { remember(Self.fourCC("NZCL"), 6, UInt32(shortcut.keyCode), modifiers) }
        }
        for (index, entry) in namedHotkeys.enumerated() {
            guard let shortcut = entry.activationShortcut, shortcut.isValidGlobalHotkey else { continue }
            let modifiers = UInt32((shortcut.modifiers & (1 << 18) != 0 ? 4096 : 0) |
                (shortcut.modifiers & (1 << 19) != 0 ? 2048 : 0) |
                (shortcut.modifiers & (1 << 17) != 0 ? 512 : 0) |
                (shortcut.modifiers & (1 << 20) != 0 ? 256 : 0))
            guard used.insert("\(shortcut.keyCode):\(modifiers)").inserted else {
                ShortcutSettings.shared.error = "\(entry.name) conflicts with another global hotkey."; continue
            }
            let id = UInt32(index)
            var ref: EventHotKeyRef?
            let result = RegisterEventHotKey(UInt32(shortcut.keyCode), modifiers,
                EventHotKeyID(signature: Self.fourCC("RMAC"), id: id), GetApplicationEventTarget(), 0, &ref)
            if result == noErr { namedHotkeyIDs[id] = entry.id; actionRefs.append(ref); remember(Self.fourCC("RMAC"), id, UInt32(shortcut.keyCode), modifiers) }
            else { ShortcutSettings.shared.error = "\(entry.name) hotkey is unavailable." }
        }
        for (index, binding) in actionBindings.enumerated() {
            guard binding.trigger.isValid, binding.action.isValid,
                  let shortcut = binding.trigger.keyboard, shortcut.isValidGlobalHotkey else { continue }
            let modifiers = UInt32((shortcut.modifiers & (1 << 18) != 0 ? 4096 : 0) |
                (shortcut.modifiers & (1 << 19) != 0 ? 2048 : 0) |
                (shortcut.modifiers & (1 << 17) != 0 ? 512 : 0) |
                (shortcut.modifiers & (1 << 20) != 0 ? 256 : 0))
            guard used.insert("\(shortcut.keyCode):\(modifiers)").inserted else {
                ShortcutSettings.shared.error = "\(binding.trigger.title) conflicts with another global hotkey."
                continue
            }
            let id = UInt32(index)
            var ref: EventHotKeyRef?
            let result = RegisterEventHotKey(UInt32(shortcut.keyCode), modifiers,
                EventHotKeyID(signature: Self.fourCC("RBND"), id: id), GetApplicationEventTarget(), 0, &ref)
            if result == noErr { bindingActions[id] = binding.action; actionRefs.append(ref); remember(Self.fourCC("RBND"), id, UInt32(shortcut.keyCode), modifiers) }
            else { ShortcutSettings.shared.error = "\(binding.trigger.title) is unavailable."
            }
        }
    }

    private func handle(id: UInt32, down: Bool) {
        guard !recording else { return }
        if id == 6 {
            if down { guard pressed.insert(id).inserted else { return } }
            else { pressed.remove(id) }
            onExplorerHold?(down)
            return
        }
        if (3...5).contains(id) {
            if down { guard pressed.insert(id).inserted else { return } }
            else { pressed.remove(id) }
            onAction?(id, down)
            return
        }
        guard let hold = profileHolds[id] else { return }
        let previous = activation.active
        let current = activation.handle(id: id, down: down, hold: hold)
        onProfileChanged?(current)
        if previous != current { registerActions() }
    }

    private static func fourCC(_ string: String) -> OSType {
        string.utf8.reduce(0) { ($0 << 8) + OSType($1) }
    }
}
