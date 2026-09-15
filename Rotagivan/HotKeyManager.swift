import Carbon
import Foundation
import Combine

struct ProfileShortcut: Codable, Equatable {
    var keyCode: UInt32 = 64
    var modifiers: UInt32 = 0
    var enabled = false
}

@MainActor
final class ShortcutSettings: ObservableObject {
    static let shared = ShortcutSettings()
    @Published var normal: ProfileShortcut { didSet { save() } }
    @Published var precision: ProfileShortcut { didSet { save() } }
    @Published var hold: Bool { didSet { save() } }
    @Published var error: String?
    @Published var actions: [ProfileShortcut] { didSet { save() } }
    static let keys: [(String, UInt32)] = [("F1",122),("F2",120),("F3",99),("F4",118),("F5",96),("F6",97),("F7",98),("F8",100),("F9",101),("F10",109),("F11",103),("F12",111),("F13",105),("F14",107),("F15",113),("F16",106),("F17",64),("F18",79),("F19",80),("F20",90)] + Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ").enumerated().map { index, letter in
        (String(letter), [UInt32(0),11,8,2,14,3,5,4,34,38,40,37,46,45,31,35,12,15,1,17,32,9,13,7,16,6][index])
    }
    private init() {
        func read(_ key: String) -> ProfileShortcut? {
            UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(ProfileShortcut.self, from: $0) }
        }
        normal = read("shortcut.normal") ?? ProfileShortcut()
        actions = (3...5).map { read("shortcut.action.\($0)") ?? ProfileShortcut(keyCode: UInt32($0 == 3 ? 79 : $0 == 4 ? 80 : 90)) }
        precision = read("shortcut.precision") ?? ProfileShortcut(enabled: true)
        hold = UserDefaults.standard.object(forKey: "shortcut.hold") as? Bool ?? true
    }
    private func save() {
        for (index, action) in actions.enumerated() { UserDefaults.standard.set(try? JSONEncoder().encode(action), forKey: "shortcut.action.\(index + 3)") }
        UserDefaults.standard.set(try? JSONEncoder().encode(normal), forKey: "shortcut.normal")
        UserDefaults.standard.set(try? JSONEncoder().encode(precision), forKey: "shortcut.precision")
        UserDefaults.standard.set(hold, forKey: "shortcut.hold")
    }
}

@MainActor
final class HotKeyManager {
    var onPrecisionChanged: ((Bool) -> Void)?
    var onAction: ((UInt32, Bool) -> Void)?
    private var refs: [EventHotKeyRef?] = []
    private var handler: EventHandlerRef?
    private var pressed = Set<UInt32>()
    private var observation: AnyCancellable?
    private var order: [UInt32] = []

    func install() {
        guard handler == nil else { return }
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

        observation = ShortcutSettings.shared.$normal.combineLatest(ShortcutSettings.shared.$precision, ShortcutSettings.shared.$hold, ShortcutSettings.shared.$actions)
            .sink { [weak self] normal, precision, hold, actions in
                self?.register(normal: normal, precision: precision, hold: hold, actions: actions)
            }
    }

    private func register(normal: ProfileShortcut, precision: ProfileShortcut, hold: Bool, actions: [ProfileShortcut]) {
        onAction?(5, false)
        refs.compactMap { $0 }.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        pressed.removeAll()
        order.removeAll()
        onPrecisionChanged?(false)
        ShortcutSettings.shared.error = nil
        let all = [normal, precision] + actions
        let enabled = all.filter(\.enabled)
        if Set(enabled.map { "\($0.keyCode):\($0.modifiers)" }).count != enabled.count {
            ShortcutSettings.shared.error = "Choose a unique shortcut for each profile and mouse action."
            return
        }
        for (index, shortcut) in all.enumerated() where shortcut.enabled {
            let id = UInt32(index + 1)
            if shortcut.keyCode < 64 && shortcut.modifiers == 0 {
                ShortcutSettings.shared.error = "Letter shortcuts need at least one modifier."
                continue
            }
            var ref: EventHotKeyRef?
            let result = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, EventHotKeyID(signature: Self.fourCC("NZCL"), id: id), GetApplicationEventTarget(), 0, &ref)
            if result != noErr { ShortcutSettings.shared.error = "\(["Normal", "Precision", "Single click", "Double click", "Hold to drag"][index]) shortcut is unavailable. Choose another combination." }
            refs.append(ref)
        }
    }

    private func handle(id: UInt32, down: Bool) {
        if id >= 3 {
            if down { guard pressed.insert(id).inserted else { return } }
            else { pressed.remove(id) }
            onAction?(id, down)
            return
        }
        if down {
            guard pressed.insert(id).inserted else { return }
            order.append(id)
            onPrecisionChanged?(id == 2)
        } else {
            pressed.remove(id)
            order.removeAll { $0 == id }
            if ShortcutSettings.shared.hold { onPrecisionChanged?(order.last == 2) }
        }
    }

    private static func fourCC(_ string: String) -> OSType {
        string.utf8.reduce(0) { ($0 << 8) + OSType($1) }
    }
}
