import Carbon
import Foundation
import Combine

extension Notification.Name {
    static let shortcutRecordingStarted = Notification.Name("Rotagivan.shortcutRecordingStarted")
    static let shortcutRecordingStopped = Notification.Name("Rotagivan.shortcutRecordingStopped")
}

struct ProfileShortcut: Codable, Equatable {
    var keyCode: UInt32 = 64
    var modifiers: UInt32 = 0
    var enabled = false
    var holdToActivate: Bool? = nil
    var keyLabel: String? = nil
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
    private var replacingConfiguration = false

    func replaceConfiguration(normal: ProfileShortcut, precision: ProfileShortcut,
                              actions: [ProfileShortcut], additional: [UInt32: ProfileShortcut],
                              profileActions: [UInt32: [ProfileShortcut]], holdToActivate: Bool) {
        replacingConfiguration = true
        self.normal = normal
        self.precision = precision
        self.actions = actions
        self.additional = additional
        self.profileActions = profileActions
        UserDefaults.standard.set(holdToActivate, forKey: "shortcut.hold")
        replacingConfiguration = false
        save()
    }

    func actions(for id: UInt32) -> [ProfileShortcut] {
        guard let saved = profileActions[id], saved.count == 3 else { return actions }
        return saved
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
        profileActions = UserDefaults.standard.data(forKey: "shortcut.profileActions").flatMap { try? JSONDecoder().decode([UInt32: [ProfileShortcut]].self, from: $0) } ?? [:]
        additional = UserDefaults.standard.data(forKey: "shortcut.additional").flatMap { try? JSONDecoder().decode([UInt32: ProfileShortcut].self, from: $0) } ?? [:]
        actions = (3...5).map { read("shortcut.action.\($0)") ?? ProfileShortcut(keyCode: UInt32($0 == 3 ? 79 : $0 == 4 ? 80 : 90)) }
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
    private var customTapProfiles = Set<UInt32>()
    private var defaultProfileID: UInt32 = 1

    func configureProfiles(defaultID: UInt32, customTaps: Set<UInt32>) {
        let changed = defaultProfileID != defaultID
        defaultProfileID = defaultID
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

    static func resolvedActions(for id: UInt32, defaults: [ProfileShortcut], saved: [UInt32: [ProfileShortcut]], customTapProfiles: Set<UInt32>, defaultID: UInt32 = 1) -> [ProfileShortcut] {
        let own = saved[id]?.count == 3 ? saved[id]! : defaults
        let primary = saved[defaultID]?.count == 3 ? saved[defaultID]! : defaults
        guard id != defaultID, !customTapProfiles.contains(id), own.count == 3, primary.count == 3 else { return own }
        return [primary[0], primary[1], own[2]]
    }
    private var profileCombinations = Set<String>()
    private var profileError: String?
    private var recording = false
    private var recordingObservers = Set<AnyCancellable>()
    private var activation = ProfileActivationState()
    private var profileHolds: [UInt32: Bool] = [:]

    func install() {
        guard handler == nil else { return }
        NotificationCenter.default.publisher(for: .shortcutRecordingStarted).sink { [weak self] _ in
            guard let self else { return }
            self.recording = true
            self.onExplorerHold?(false)
            self.onAction?(5, false)
            (self.refs + self.actionRefs).compactMap { $0 }.forEach { UnregisterEventHotKey($0) }
            self.refs.removeAll()
            self.actionRefs.removeAll()
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
            DispatchQueue.main.async { owner.handle(id: id.id, down: down) }
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), callback, eventTypes.count, &eventTypes, Unmanaged.passUnretained(self).toOpaque(), &handler)

        observation = ShortcutSettings.shared.$normal.combineLatest(ShortcutSettings.shared.$precision, ShortcutSettings.shared.$additional)
            .sink { [weak self] normal, precision, additional in
                self?.register(normal: normal, precision: precision, additional: additional)
            }
        actionObservation = ShortcutSettings.shared.$actions.combineLatest(ShortcutSettings.shared.$profileActions)
            .sink { [weak self] actions, saved in
                self?.defaultActions = actions
                self?.savedActions = saved
                self?.registerActions()
            }
    }

    private func register(normal: ProfileShortcut, precision: ProfileShortcut, additional: [UInt32: ProfileShortcut], resetActivation: Bool = true) {
        guard !recording else { return }
        onAction?(5, false)
        actionRefs.compactMap { $0 }.forEach { UnregisterEventHotKey($0) }
        actionRefs.removeAll()
        refs.compactMap { $0 }.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        pressed.removeAll()
        if resetActivation { activation = ProfileActivationState(defaultID: defaultProfileID) }
        profileHolds = [1: normal.holdToActivate ?? true, 2: precision.holdToActivate ?? true]
        for (id, shortcut) in additional { profileHolds[id] = shortcut.holdToActivate ?? true }
        profileHolds.removeValue(forKey: defaultProfileID)
        onProfileChanged?(activation.active)
        ShortcutSettings.shared.error = nil
        let configured: [(id: UInt32, name: String, shortcut: ProfileShortcut)] =
            [(1, "Normal", normal), (2, "Precision", precision)] +
            additional.sorted { $0.key < $1.key }.map { ($0.key, "Profile \($0.key - 97)", $0.value) }
        let all = configured.filter { $0.id != defaultProfileID }
        let enabled = all.map(\.shortcut).filter(\.enabled)
        profileCombinations = Set(enabled.map { "\($0.keyCode):\($0.modifiers)" })
        defer {
            profileError = ShortcutSettings.shared.error
            registerActions()
        }
        if Set(enabled.map { "\($0.keyCode):\($0.modifiers)" }).count != enabled.count {
            ShortcutSettings.shared.error = "Choose a unique shortcut for each profile and mouse action."
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
        }
    }

    private func registerActions() {
        guard !recording else { return }
        onExplorerHold?(false)
        // Releasing before replacing registrations prevents a stuck drag on profile changes.
        onAction?(5, false)
        pressed.removeAll()
        actionRefs.compactMap { $0 }.forEach { UnregisterEventHotKey($0) }
        actionRefs.removeAll()
        ShortcutSettings.shared.error = profileError
        let actions = Self.resolvedActions(for: activation.active, defaults: defaultActions, saved: savedActions, customTapProfiles: customTapProfiles, defaultID: defaultProfileID)
        var used = profileCombinations
        for (index, shortcut) in actions.prefix(3).enumerated() where shortcut.enabled {
            let name = ["Click at cursor", "Double-click at cursor", "Keyboard drag"][index]
            let combination = "\(shortcut.keyCode):\(shortcut.modifiers)"
            guard used.insert(combination).inserted else {
                ShortcutSettings.shared.error = "\(name) conflicts with another shortcut in this profile."
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
        }
        if let shortcut = explorerShortcut {
            let modifiers = UInt32((shortcut.modifiers & (1 << 18) != 0 ? 4096 : 0) |
                (shortcut.modifiers & (1 << 19) != 0 ? 2048 : 0) |
                (shortcut.modifiers & (1 << 17) != 0 ? 512 : 0) |
                (shortcut.modifiers & (1 << 20) != 0 ? 256 : 0))
            guard used.insert("\(shortcut.keyCode):\(modifiers)").inserted else {
                ShortcutSettings.shared.error = "App Explorer conflicts with a profile or mouse shortcut."; return
            }
            guard shortcut.keyCode >= 64 || modifiers != 0 else {
                ShortcutSettings.shared.error = "App Explorer letter shortcuts need a modifier."; return
            }
            var ref: EventHotKeyRef?
            let result = RegisterEventHotKey(UInt32(shortcut.keyCode), modifiers, EventHotKeyID(signature: Self.fourCC("NZCL"), id: 6), GetApplicationEventTarget(), 0, &ref)
            if result != noErr { ShortcutSettings.shared.error = "App Explorer shortcut is unavailable. Choose another combination." }
            actionRefs.append(ref)
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
