import Foundation

struct BindingTrigger: Codable, Equatable {
    var keyboard: RecordedShortcut? = nil
    var gesture: AppGestureTrigger? = nil
    var identity: String { keyboard.map { "key:" + $0.identity } ?? gesture.map { "gesture:" + $0.rawValue } ?? "unassigned" }
    var title: String { keyboard?.readableCombination ?? gesture?.title ?? "Choose trigger" }
    var isValid: Bool { (keyboard?.isPhysicalShortcut == true && gesture == nil) || (keyboard == nil && gesture != nil) }
}

enum HUDNavigationAction: String, Codable, CaseIterable {
    case previous, next, above, below, topLeft, topRight, bottomLeft, bottomRight
    var title: String {
        switch self {
        case .previous: return "Previous HUD (left)"
        case .next: return "Next HUD (right)"
        case .above: return "HUD above"
        case .below: return "HUD below"
        case .topLeft: return "HUD top left"
        case .topRight: return "HUD top right"
        case .bottomLeft: return "HUD bottom left"
        case .bottomRight: return "HUD bottom right"
        }
    }
    var symbol: String {
        switch self {
        case .previous: return "chevron.left.2"
        case .next: return "chevron.right.2"
        case .above: return "chevron.up.2"
        case .below: return "chevron.down.2"
        case .topLeft: return "arrow.up.left"
        case .topRight: return "arrow.up.right"
        case .bottomLeft: return "arrow.down.left"
        case .bottomRight: return "arrow.down.right"
        }
    }
    var step: HUDMapPoint {
        switch self {
        case .previous: return HUDMapPoint(x: -1, y: 0)
        case .next: return HUDMapPoint(x: 1, y: 0)
        case .above: return HUDMapPoint(x: 0, y: 1)
        case .below: return HUDMapPoint(x: 0, y: -1)
        case .topLeft: return HUDMapPoint(x: -1, y: 1)
        case .topRight: return HUDMapPoint(x: 1, y: 1)
        case .bottomLeft: return HUDMapPoint(x: -1, y: -1)
        case .bottomRight: return HUDMapPoint(x: 1, y: -1)
        }
    }
}

enum HUDSwipeDirection: String, Codable, CaseIterable {
    case inverted, regular
    var title: String { self == .inverted ? "Inverted (default)" : "Regular" }

    /// Equal 45-degree sectors; hardware Y grows downward.
    func navigation(dx: Double, dy: Double) -> HUDNavigationAction {
        let diagonal = min(abs(dx), abs(dy)) > max(abs(dx), abs(dy)) * 0.41421356237
        let sign = self == .inverted ? -1 : 1
        let x = (dx < 0 ? -1 : 1) * sign
        let y = (dy < 0 ? 1 : -1) * sign
        if diagonal {
            return x < 0 ? (y > 0 ? .topLeft : .bottomLeft) : (y > 0 ? .topRight : .bottomRight)
        }
        return abs(dx) >= abs(dy) ? (x < 0 ? .previous : .next) : (y > 0 ? .above : .below)
    }

    /// Inverted drags the surface with the fingers; regular follows the swipe.
    /// This affects only default two-finger HUD gestures, never keyboard actions.
    func navigation(for trigger: AppGestureTrigger) -> HUDNavigationAction? {
        switch trigger {
        case .twoFingerLeft: return self == .inverted ? .next : .previous
        case .twoFingerRight: return self == .inverted ? .previous : .next
        case .twoFingerUp: return self == .inverted ? .below : .above
        case .twoFingerDown: return self == .inverted ? .above : .below
        default: return nil
        }
    }
}

enum HUDLayerPosition: String, Codable, CaseIterable, Identifiable {
    case left, right, top, bottom, topLeft, topRight, bottomLeft, bottomRight
    var id: Self { self }
    // Keep legacy cardinal assignments stable before filling the new corners.
    static let legacyOrder: [Self] = [.right, .bottom, .left, .top, .topLeft, .topRight, .bottomLeft, .bottomRight]
    var title: String {
        switch self {
        case .topLeft: return "Top left"
        case .topRight: return "Top right"
        case .bottomLeft: return "Bottom left"
        case .bottomRight: return "Bottom right"
        default: return rawValue.capitalized
        }
    }
    var symbol: String {
        switch self {
        case .left: return "arrow.left"
        case .right: return "arrow.right"
        case .top: return "arrow.up"
        case .bottom: return "arrow.down"
        case .topLeft: return "arrow.up.left"
        case .topRight: return "arrow.up.right"
        case .bottomLeft: return "arrow.down.left"
        case .bottomRight: return "arrow.down.right"
        }
    }
    var x: Int {
        switch self {
        case .left, .topLeft, .bottomLeft: return -1
        case .right, .topRight, .bottomRight: return 1
        default: return 0
        }
    }
    var y: Int {
        switch self {
        case .top, .topLeft, .topRight: return 1
        case .bottom, .bottomLeft, .bottomRight: return -1
        default: return 0
        }
    }
    var point: HUDMapPoint { HUDMapPoint(x: x, y: y) }
}

/// Coordinates never change when another HUD becomes active. Main is (0, 0).
struct HUDMapPoint: Equatable, Hashable {
    var x: Int
    var y: Int
    static let zero = Self(x: 0, y: 0)
    static func - (lhs: Self, rhs: Self) -> Self { Self(x: lhs.x - rhs.x, y: lhs.y - rhs.y) }

    /// Swipes follow their row, column, or diagonal ray without wrapping.
    func distance(in direction: HUDNavigationAction) -> Int? {
        let forward: Int
        switch direction {
        case .next: guard y == 0 else { return nil }; forward = x
        case .previous: guard y == 0 else { return nil }; forward = -x
        case .above: guard x == 0 else { return nil }; forward = y
        case .below: guard x == 0 else { return nil }; forward = -y
        case .topLeft: guard x == -y else { return nil }; forward = y
        case .topRight: guard x == y else { return nil }; forward = y
        case .bottomLeft: guard x == y else { return nil }; forward = -y
        case .bottomRight: guard x == -y else { return nil }; forward = -y
        }
        return forward > 0 ? forward : nil
    }
    static func nearestIndex(in offsets: [Self], toward direction: HUDNavigationAction) -> Int? {
        offsets.indices.compactMap { index in
            offsets[index].distance(in: direction).map { (index: index, distance: $0) }
        }.min { $0.distance < $1.distance }?.index
    }
}

struct HUDMapNode: Identifiable {
    let layerID: UUID?
    let name: String
    let point: HUDMapPoint
    let favorites: [AppExplorerFavorite]
    let slotCount: Int
    var builtIn: HUDLayerBuiltIn? = nil
    var id: String { layerID?.uuidString ?? "main" }
}

/// Built-in outputs, not registered global hotkeys or seeded user macros.
/// Keeping presets separate means upgrades never overwrite saved actions.
struct CommonMacShortcut {
    let name: String
    let keyCode: UInt16
    let keyLabel: String
    let modifiers: UInt64
    let detail: String

    var action: BindingAction {
        BindingAction(kind: .keystroke, keyCode: keyCode, modifiers: modifiers, keyLabel: keyLabel, name: name)
    }

    static let all: [Self] = {
        let command = UInt64(1 << 20), shift = UInt64(1 << 17), option = UInt64(1 << 19)
        return [
            Self(name: "Copy", keyCode: 8, keyLabel: "C", modifiers: command, detail: "Copy the selection to the clipboard."),
            Self(name: "Cut", keyCode: 7, keyLabel: "X", modifiers: command, detail: "Cut the selection to the clipboard in apps that support it."),
            Self(name: "Paste", keyCode: 9, keyLabel: "V", modifiers: command, detail: "Paste the clipboard into the active app."),
            Self(name: "Paste and match style", keyCode: 9, keyLabel: "V", modifiers: command | option | shift, detail: "Paste using the destination formatting in apps that support this shortcut."),
            Self(name: "Undo", keyCode: 6, keyLabel: "Z", modifiers: command, detail: "Undo the last edit."),
            Self(name: "Redo", keyCode: 6, keyLabel: "Z", modifiers: command | shift, detail: "Redo the last undone edit in apps using the standard Mac shortcut."),
            Self(name: "Select all", keyCode: 0, keyLabel: "A", modifiers: command, detail: "Select all content in the active field or view."),
            Self(name: "Save", keyCode: 1, keyLabel: "S", modifiers: command, detail: "Save the current document; a new document may prompt for a location."),
            Self(name: "Find", keyCode: 3, keyLabel: "F", modifiers: command, detail: "Open the active app’s search or find bar."),
            Self(name: "Find next", keyCode: 5, keyLabel: "G", modifiers: command, detail: "Jump to the next search match in apps that support it."),
            Self(name: "New window or document", keyCode: 45, keyLabel: "N", modifiers: command, detail: "Create a new window or document, depending on the app."),
            Self(name: "New tab", keyCode: 17, keyLabel: "T", modifiers: command, detail: "Open a new tab in apps that support tabs."),
            Self(name: "Close tab or window", keyCode: 13, keyLabel: "W", modifiers: command, detail: "Close the active tab or window. The app may ask about unsaved changes."),
            Self(name: "Reopen closed tab", keyCode: 17, keyLabel: "T", modifiers: command | shift, detail: "Reopen the last closed tab in supported browsers."),
            Self(name: "Reload", keyCode: 15, keyLabel: "R", modifiers: command, detail: "Reload the current page in supported browsers; other apps may use this key differently."),
            Self(name: "Focus address bar", keyCode: 37, keyLabel: "L", modifiers: command, detail: "Select the address bar in supported browsers."),
            Self(name: "App settings", keyCode: 43, keyLabel: ",", modifiers: command, detail: "Open the active app’s settings if it supports Command–comma."),
            Self(name: "Spotlight", keyCode: 49, keyLabel: "Space", modifiers: command, detail: "Open Spotlight using its default shortcut; macOS shortcut customizations may change this."),
            Self(name: "Screenshot selection", keyCode: 21, keyLabel: "4", modifiers: command | shift, detail: "Start a screenshot selection using the default macOS shortcut."),
            Self(name: "Screenshot controls", keyCode: 23, keyLabel: "5", modifiers: command | shift, detail: "Open screenshot and screen-recording controls using the default macOS shortcut.")
        ]
    }()
}

/// A destination is independent of the input that invokes it. Physical output
/// keys are stored as scalars so references cannot recursively contain actions.
struct BindingAction: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case keystroke, macro, hudLayer, hudNavigation, openApp, openURL, command, media, windowPlacement, tap
    }
    var kind: Kind
    var keyCode: UInt16? = nil
    var modifiers: UInt64? = nil
    var keyLabel: String? = nil
    var macroID: String? = nil
    var hudLayerID: UUID? = nil
    var hudPath: [String]? = nil
    var windowOwnerPath: [String]? = nil
    var hudNavigation: HUDNavigationAction? = nil
    var bundleID: String? = nil
    var name: String? = nil
    var url: String? = nil
    var command: AppExplorerAction? = nil
    var media: ExplorerMediaAction? = nil
    var windowPlacement: ExplorerWindowPlacement? = nil
    var tap: TapAction? = nil
    var shortcut: RecordedShortcut? {
        guard kind == .keystroke, let keyCode, let modifiers, let keyLabel else { return nil }
        return RecordedShortcut(keyCode: keyCode, modifiers: modifiers, keyLabel: keyLabel)
    }
    var title: String {
        switch kind {
        case .keystroke: return name.map { "\($0) · \(shortcut?.readableCombination ?? "Keystroke")" } ?? shortcut?.readableCombination ?? "Keystroke"
        case .macro: return name ?? "Saved action"
        case .hudLayer: return "Open HUD · " + (name ?? (hudLayerID == nil ? "Default" : "Layer"))
        case .hudNavigation: return hudNavigation?.title ?? "Navigate HUD"
        case .openApp: return "Open " + (name ?? bundleID ?? "app")
        case .openURL: return name ?? url ?? "Open URL"
        case .command: return command?.title ?? "Command"
        case .media: return media?.title ?? "Media"
        case .windowPlacement: return windowPlacement?.title ?? "Place window"
        case .tap: return tap?.title ?? "Pointer action"
        }
    }
    var description: String {
        switch kind {
        case .keystroke: return (CommonMacShortcut.all.first { $0.name == name && $0.action.shortcut == shortcut }.map { $0.detail + " " } ?? "") + "Send \(shortcut?.readableCombination ?? "the chosen keys") to the active app. This is the output, not the keybinding that triggers it."
        case .macro: return "Run the saved macro’s steps in order. A macro can contain keystrokes and app launches."
        case .hudLayer: return "Open \(name ?? "the selected HUD layer") so you can choose one of its actions."
        case .hudNavigation: return "Move to \(hudNavigation?.title ?? "the selected HUD") in the fixed HUD map without closing it."
        case .openApp: return "Launch or activate \(name ?? bundleID ?? "the selected app")."
        case .openURL: return "Open \(url ?? "the selected URL") in the default browser."
        case .command: return command?.description ?? "Choose a Mac or window command."
        case .media:
            switch media {
            case .volumeUp: return "Increase system output volume by one step."
            case .volumeDown: return "Decrease system output volume by one step."
            case .mute: return "Toggle system output mute."
            case .playPause: return "Play or pause the current media session."
            case .next: return "Skip to the next track in the current media session."
            case .previous: return "Return to the previous track in the current media session."
            case nil: return "Choose an audio or playback action."
            }
        case .windowPlacement: return "Move and resize the focused window to \(windowPlacement?.title ?? "the selected layout") within its current desktop."
        case .tap:
            switch tap {
            case .leftClick: return "Send a left mouse click at the pointer."
            case .doubleLeftClick: return "Send a double left click at the pointer."
            case .tripleLeftClick: return "Send a triple left click at the pointer."
            case .rightClick: return "Open the context menu with a right click at the pointer."
            case .enter: return "Send the Return key to the active app."
            case .optionF19: return "Send Option–F19 to the active app."
            case .appExplorer: return "Open the main HUD."
            case .windowManager: return AppExplorerAction.windowManager.description
            case .some(.none): return "Do not perform an action."
            case .shortcut: return "Send the configured keystroke."
            case nil: return "Choose a pointer or HUD action."
            }
        }
    }

    var identity: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? kind.rawValue
    }
    var isValid: Bool {
        if let name, name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 512 { return false }
        // Reject mixed destinations in imported configs, rather than silently
        // ignoring fields belonging to a different action kind.
        let hasKey = keyCode != nil || modifiers != nil || keyLabel != nil
        guard !hasKey || kind == .keystroke,
              macroID == nil || kind == .macro,
              hudLayerID == nil || kind == .hudLayer,
              hudPath == nil || (kind == .hudLayer && hudLayerID == nil),
              windowOwnerPath == nil || (kind == .hudLayer && hudPath != nil && hudLayerID == nil),
              hudNavigation == nil || kind == .hudNavigation,
              bundleID == nil || kind == .openApp,
              url == nil || kind == .openURL,
              command == nil || kind == .command,
              media == nil || kind == .media,
              windowPlacement == nil || kind == .windowPlacement,
              tap == nil || kind == .tap else { return false }
        switch kind {
        case .keystroke: return shortcut?.isPhysicalShortcut == true
        case .macro: return macroID.map { !$0.isEmpty && $0.count <= 128 } ?? false
        case .hudLayer:
            let validPath: ([String]) -> Bool = { $0.count <= 16 && $0.allSatisfy { ExplorerTilePathStep(token: $0) != nil } }
            guard hudPath.map(validPath) ?? true, windowOwnerPath.map(validPath) ?? true else { return false }
            if let owner = windowOwnerPath, !owner.isEmpty {
                guard case .group? = owner.last.flatMap(ExplorerTilePathStep.init(token:)) else { return false }
            }
            return true
        case .hudNavigation: return hudNavigation != nil
        case .openApp:
            return bundleID.map {
                !$0.isEmpty && $0.count <= 255 && $0 != "local.rotagivan" && $0.contains(".") &&
                $0.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-").contains($0) }
            } ?? false
        case .openURL: return url.flatMap(AppExplorerFavorite.webURL) != nil
        case .command: return command != nil
        case .media: return media != nil
        case .windowPlacement: return windowPlacement != nil
        case .tap: return tap.map { $0 != .none && $0 != .shortcut } ?? false
        }
    }
    static func keystroke(_ key: RecordedShortcut) -> Self {
        Self(kind: .keystroke, keyCode: key.keyCode, modifiers: key.modifiers, keyLabel: key.keyLabel)
    }
    static func macro(_ entry: NamedHotkey) -> Self { Self(kind: .macro, macroID: entry.id, name: entry.name) }
    static func hudLayer(_ layer: ExplorerHoldLayer?) -> Self { Self(kind: .hudLayer, hudLayerID: layer?.id, name: layer?.name ?? "Default") }
    static func hudContainer(_ container: ExplorerTileContainer) -> Self {
        Self(kind: .hudLayer, hudPath: container.id.map(\.token), name: container.title)
    }
    static func hudDestination(_ destination: HUDActionDestination) -> Self {
        Self(kind: .hudLayer, hudPath: destination.path.map(\.token),
            windowOwnerPath: destination.windowOwnerPath?.map(\.token), name: destination.title)
    }
    static func hudNavigation(_ direction: HUDNavigationAction) -> Self { Self(kind: .hudNavigation, hudNavigation: direction) }
    static func openApp(bundleID: String, name: String) -> Self { Self(kind: .openApp, bundleID: bundleID, name: name) }
    static func openURL(_ url: String) -> Self { Self(kind: .openURL, url: url) }
    static func command(_ command: AppExplorerAction) -> Self { Self(kind: .command, command: command) }
    static func media(_ media: ExplorerMediaAction) -> Self { Self(kind: .media, media: media) }
    static func windowPlacement(_ placement: ExplorerWindowPlacement) -> Self { Self(kind: .windowPlacement, windowPlacement: placement) }
    static func tap(_ tap: TapAction) -> Self { Self(kind: .tap, tap: tap) }
    static func from(shortcut: RecordedShortcut) -> Self {
        if let action = shortcut.assignedAction { return action }
        if let id = shortcut.macroID { return Self(kind: .macro, macroID: id, name: shortcut.keyLabel) }
        if let id = shortcut.hudLayerID { return Self(kind: .hudLayer, hudLayerID: id, name: shortcut.keyLabel) }
        return .keystroke(shortcut)
    }
    static func from(favorite: AppExplorerFavorite) -> Self? {
        if let key = favorite.shortcut { return from(shortcut: key) }
        if let app = favorite.bundleID { return .openApp(bundleID: app, name: favorite.name) }
        if let url = favorite.url { return Self(kind: .openURL, name: favorite.name, url: url) }
        if let command = favorite.action { return .command(command) }
        if let placement = favorite.windowPlacement { return .windowPlacement(placement) }
        return nil
    }
    func favorite(at slot: ExplorerSlot) -> AppExplorerFavorite? {
        guard isValid else { return nil }
        switch kind {
        case .openApp: return AppExplorerFavorite(direction: slot, bundleID: bundleID, name: name ?? title)
        case .openURL: return AppExplorerFavorite(direction: slot, name: name ?? title, url: url)
        case .command: return AppExplorerFavorite(direction: slot, name: title, action: command)
        case .windowPlacement: return AppExplorerFavorite(direction: slot, name: title, windowPlacement: windowPlacement)
        default: return AppExplorerFavorite(direction: slot, name: name ?? title, shortcut: .assigned(self))
        }
    }
}

struct ActionBinding: Codable, Equatable, Identifiable {
    var id = UUID()
    var trigger: BindingTrigger
    var action: BindingAction
    var isValid: Bool { trigger.isValid && action.isValid }
}

extension Array where Element == ActionBinding {
    func isValidBindings(global: Bool = false, reservedKeys: [RecordedShortcut] = []) -> Bool {
        guard count <= 256, Set(map(\.id)).count == count else { return false }
        var keys = Set(reservedKeys.map { "key:" + $0.identity })
        for binding in self {
            guard binding.isValid, keys.insert(binding.trigger.identity).inserted else { return false }
            if let key = binding.trigger.keyboard,
               !(global ? key.isValidGlobalHotkey : key.isValidHUDActionHotkey) { return false }
        }
        return true
    }
}

enum ExplorerMediaAction: Int, Codable, CaseIterable {
    case volumeUp = 0, volumeDown = 1, mute = 7, playPause = 16, next = 17, previous = 18
    var direction: SwipeDirection {
        switch self { case .volumeUp: return .up; case .volumeDown: return .down; case .mute: return .topLeft; case .playPause: return .topRight; case .next: return .right; case .previous: return .left }
    }
    var title: String {
        switch self { case .volumeUp: return "Volume up"; case .volumeDown: return "Volume down"; case .mute: return "Mute / unmute"; case .playPause: return "Play / pause"; case .next: return "Next track"; case .previous: return "Previous track" }
    }
    var symbol: String {
        switch self { case .volumeUp: return "speaker.wave.3.fill"; case .volumeDown: return "speaker.wave.1.fill"; case .mute: return "speaker.slash.fill"; case .playPause: return "playpause.fill"; case .next: return "forward.end.fill"; case .previous: return "backward.end.fill" }
    }
}


@MainActor enum HUDSettingsNavigation {
    static var pending = false
}

extension Notification.Name {
    static let configurationProfileChanged = Notification.Name("Rotagivan.configurationProfileChanged")
    static let openHUDSettingsRequested = Notification.Name("Rotagivan.openHUDSettingsRequested")
}

// Portable top-level profiles own layer settings, Explorer layouts and shortcuts.
// StoredSettings remains the active profile projection for legacy preferences.
struct ProfileShortcut: Codable, Equatable {
    var keyCode: UInt32 = 64
    var modifiers: UInt32 = 0
    var enabled = false
    var holdToActivate: Bool? = nil
    var keyLabel: String? = nil
}

struct ShortcutConfiguration: Codable {
    var normal = ProfileShortcut()
    var precision = ProfileShortcut(enabled: true)
    var actions = [ProfileShortcut(keyCode: 79), ProfileShortcut(keyCode: 80), ProfileShortcut(keyCode: 90)]
    var additional: [UInt32: ProfileShortcut] = [:]
    var profileActions: [UInt32: [ProfileShortcut]] = [:]
    // Keyboard dragging belongs to the top-level profile. Nil preserves old
    // configurations and resolves through the default layer's third action.
    var dragShortcut: ProfileShortcut? = nil
    var holdToActivate = true

    func resolvedDragShortcut(defaultID: UInt32) -> ProfileShortcut {
        if let dragShortcut { return dragShortcut }
        let legacy = profileActions[defaultID]?.count == 3 ? profileActions[defaultID]! : actions
        return legacy.indices.contains(2) ? legacy[2] : ProfileShortcut(keyCode: 90)
    }
}

enum GestureDevice: String, Codable, CaseIterable {
    case navigator, apple
    var title: String { self == .navigator ? "ZSA Navigator" : "Apple trackpad" }
}

struct ProfileDevices: Codable, Equatable {
    var navigatorEnabled = true
    var appleEnabled = true
    var shareTapActions = true
    var appleLayerGestures: [UInt32: ProfileGestures]? = nil
}

/// Navigator-only pointer dragging. Apple's native pointer, scrolling and
/// dragging remain owned by macOS and are intentionally not mirrored here.
struct DraggingSettings: Codable, Equatable {
    var touchAndHoldDrag = true
    var dragRegrip = true
    var dragRegripWindow = 0.25

    init(touchAndHoldDrag: Bool = true, dragRegrip: Bool = true, dragRegripWindow: Double = 0.25) {
        self.touchAndHoldDrag = touchAndHoldDrag
        self.dragRegrip = dragRegrip
        self.dragRegripWindow = dragRegripWindow
    }

    init(legacy: GestureSettings) {
        touchAndHoldDrag = legacy.touchAndHoldDrag
        dragRegrip = legacy.dragRegrip
        dragRegripWindow = legacy.dragRegripWindow
    }
}

/// Learned timings belong to a top-level profile/device, never an action layer.
/// Optional fields preserve legacy layer tuning until that timing is calibrated.
struct TapCalibrationSettings: Codable, Equatable {
    var doubleTapInterval: Double? = nil
    var tripleTapFirstInterval: Double? = nil
    var tripleTapSecondInterval: Double? = nil
    var singleSwipeWindow: Double? = nil
    var singleSwipeDuration: Double? = nil
    var doubleSwipeWindow: Double? = nil

    func applying(to value: ProfileGestures) -> ProfileGestures {
        var result = value
        if let doubleTapInterval { result.gestures.doubleTapInterval = doubleTapInterval }
        if let tripleTapFirstInterval { result.gestures.tripleTapFirstInterval = tripleTapFirstInterval }
        if let tripleTapSecondInterval { result.gestures.tripleTapSecondInterval = tripleTapSecondInterval }
        if singleSwipeWindow != nil || singleSwipeDuration != nil {
            var swipe = result.singleTapSwipe ?? .singleTapDefaults
            if let singleSwipeWindow { swipe.swipeWindow = singleSwipeWindow }
            if let singleSwipeDuration { swipe.fastSwipeDuration = singleSwipeDuration }
            result.singleTapSwipe = swipe
        }
        if let doubleSwipeWindow {
            var swipe = result.doubleTapSwipe ?? DoubleTapSwipeSettings()
            swipe.swipeWindow = doubleSwipeWindow
            result.doubleTapSwipe = swipe
        }
        return result
    }
}

struct ConfigurationProfile: Codable, Identifiable {
    var id: String
    var name: String
    var settings: StoredSettings
    var shortcuts: ShortcutConfiguration
}

struct ConfigurationLibrary: Codable {
    var activeID: String
    var profiles: [ConfigurationProfile]
}

enum AppExplorerMode: String, Codable, CaseIterable {
    case favorites, recent
    var title: String { self == .favorites ? "Favorites" : "Recent apps" }
    var alternate: Self { self == .favorites ? .recent : .favorites }
}

/// Reserved catalog entries are always available. Assigned instances use the
/// existing group/shortcut schema, so exports and older saved groups stay intact.
enum ExplorerReservedGroup: String, CaseIterable, Identifiable {
    case windowManager, recentApps, actions
    var id: Self { self }
    var title: String {
        switch self {
        case .windowManager: return "Window Manager"
        case .recentApps: return "Recent Apps"
        case .actions: return "Actions"
        }
    }
    var symbol: String {
        switch self {
        case .windowManager: return "rectangle.split.2x2"
        case .recentApps: return "clock.arrow.circlepath"
        case .actions: return "command"
        }
    }
    var summary: String {
        switch self {
        case .windowManager: return "Window positions, full screen, minimize and close."
        case .recentApps: return "Running apps, ordered by most recently used."
        case .actions: return "Copy, Paste, Cut, Undo, Redo, Select All, Find and Save."
        }
    }
    func tile(at slot: ExplorerSlot, insideWindowManager: Bool = false) -> AppExplorerFavorite {
        switch self {
        case .windowManager:
            return insideWindowManager
                ? AppExplorerFavorite(direction: slot, name: title, children: ExplorerWindowPlacement.tiles(layout: .halves))
                : AppExplorerFavorite(direction: slot, name: title, action: .windowManager)
        case .recentApps:
            return AppExplorerFavorite(direction: slot, name: title, children: [], groupMode: .recent)
        case .actions:
            let keys: [(ExplorerSlot, String, UInt16, String, Bool)] = [
                (.up, "Copy", 8, "C", false), (.topRight, "Paste", 9, "V", false),
                (.right, "Cut", 7, "X", false), (.bottomRight, "Select All", 0, "A", false),
                (.down, "Undo", 6, "Z", false), (.bottomLeft, "Redo", 6, "Z", true),
                (.left, "Find", 3, "F", false), (.topLeft, "Save", 1, "S", false)
            ]
            let children = keys.map { direction, name, code, label, shift in
                AppExplorerFavorite(direction: direction, name: name, shortcut: RecordedShortcut(
                    keyCode: code, modifiers: (1 << 20) | (shift ? (1 << 17) : 0), keyLabel: label))
            }
            return AppExplorerFavorite(direction: slot, name: title, children: children, slotCount: 8)
        }
    }
}

enum AppExplorerAction: String, Codable, CaseIterable {
    case toggleStageManager
    case toggleDock, previousApp, nextAppWindow, previousAppWindow, appExpose, hideApp, hideOtherApps
    case moveWindowPreviousDesktop, moveWindowNextDesktop
    case windowManager, mediaControls, appWindows, missionControl, previousDesktop, nextDesktop, showDesktop, lockScreen
    case maximize, toggleFullScreen, exitFullScreen, minimize, closeWindow
    var title: String {
        switch self {
        case .windowManager: return "Window Manager"
        case .mediaControls: return "Media Controls"
        case .appWindows: return "Show current app’s windows"
        case .missionControl: return "Mission Control"
        case .previousDesktop: return "Previous desktop"
        case .nextDesktop: return "Next desktop"
        case .showDesktop: return "Show Desktop"
        case .toggleStageManager: return "Toggle Stage Manager"
        case .toggleDock: return "Show / hide Dock"
        case .previousApp: return "Previous app"
        case .nextAppWindow: return "Next window in app"
        case .previousAppWindow: return "Previous window in app"
        case .appExpose: return "App Exposé"
        case .hideApp: return "Hide current app"
        case .hideOtherApps: return "Hide other apps"
        case .moveWindowPreviousDesktop: return "Move window to left desktop"
        case .moveWindowNextDesktop: return "Move window to right desktop"
        case .lockScreen: return "Lock Screen"
        case .maximize: return "Fill desktop"
        case .toggleFullScreen: return "Toggle full screen"
        case .exitFullScreen: return "Exit full screen"
        case .minimize: return "Minimize window"
        case .closeWindow: return "Close window"
        }
    }
    var symbol: String {
        switch self {
        case .windowManager: return "rectangle.split.2x2"
        case .mediaControls: return "speaker.wave.2.fill"
        case .appWindows: return "macwindow.on.rectangle"
        case .missionControl: return "rectangle.3.group"
        case .previousDesktop: return "arrow.left.square"
        case .nextDesktop: return "arrow.right.square"
        case .showDesktop: return "menubar.dock.rectangle"
        case .toggleStageManager: return "rectangle.3.group"
        case .toggleDock: return "dock.rectangle"
        case .previousApp: return "arrow.left.arrow.right"
        case .nextAppWindow: return "macwindow.on.rectangle"
        case .previousAppWindow: return "macwindow.on.rectangle"
        case .appExpose: return "rectangle.on.rectangle"
        case .hideApp: return "eye.slash"
        case .hideOtherApps: return "eye"
        case .moveWindowPreviousDesktop: return "arrow.left.square"
        case .moveWindowNextDesktop: return "arrow.right.square"
        case .lockScreen: return "lock.display"
        case .maximize: return "arrow.up.left.and.arrow.down.right"
        case .toggleFullScreen: return "arrow.up.left.and.down.right.and.arrow.up.right.and.down.left"
        case .exitFullScreen: return "arrow.down.right.and.arrow.up.left"
        case .minimize: return "minus.rectangle"
        case .closeWindow: return "xmark.rectangle"
        }
    }
    var description: String {
        switch self {
        case .toggleStageManager: return "Turn Stage Manager on or off using your macOS shortcut. First enable Turn Stage Manager on/off in System Settings → Keyboard → Keyboard Shortcuts → Mission Control. No shortcut is assigned automatically."
        case .toggleDock: return "Toggle automatic hiding of the Dock with Option–Command–D."
        case .previousApp: return "Switch to the most recently used other app with Command–Tab. Repeating toggles between the last two apps."
        case .nextAppWindow: return "Cycle forward through windows of the current app with Command–backtick—not through different apps."
        case .previousAppWindow: return "Cycle backward through windows of the current app with Shift–Command–backtick."
        case .appExpose: return "Show macOS App Exposé for the current app using its configured shortcut or Control–Down."
        case .hideApp: return "Hide the current app and its windows with Command–H."
        case .hideOtherApps: return "Hide other apps while keeping the current app visible with Option–Command–H."
        case .moveWindowPreviousDesktop: return "Move only the focused window to the adjacent normal desktop on the left, on the same display. Does not switch desktops or wrap; full-screen and all-desktop windows are not supported."
        case .moveWindowNextDesktop: return "Move only the focused window to the adjacent normal desktop on the right, on the same display. Does not switch desktops or wrap; full-screen and all-desktop windows are not supported."
        case .windowManager: return "Open the HUD for arranging the current app’s window."
        case .mediaControls: return "Open volume, playback, and track controls. A single tap plays or pauses."
        case .appWindows: return "Show macOS Application Windows for the current app using its configured shortcut or Control–Down."
        case .missionControl: return "Show Mission Control using your configured macOS shortcut, or Control–Up."
        case .previousDesktop: return "Switch to the desktop or full-screen Space on the left using your macOS shortcut."
        case .nextDesktop: return "Switch to the desktop or full-screen Space on the right using your macOS shortcut."
        case .showDesktop: return "Reveal the desktop using your macOS shortcut; invoke again to restore windows."
        case .lockScreen: return "Lock this Mac immediately with Control–Command–Q. Unlock with your usual credentials."
        case .maximize: return "Resize the focused window to fill the usable desktop without entering full screen."
        case .toggleFullScreen: return "Enter or leave the focused window’s separate full-screen Space."
        case .exitFullScreen: return "Leave full-screen mode for the focused window."
        case .minimize: return "Minimize the focused window into the Dock."
        case .closeWindow: return "Close the focused window. The app may ask about unsaved changes."
        }
    }
    static let windowCommands: [Self] = [.maximize, .toggleFullScreen, .exitFullScreen, .minimize, .closeWindow]
    static let macOSCommands: [Self] = [.toggleStageManager, .toggleDock, .previousApp, .nextAppWindow, .previousAppWindow, .appExpose, .missionControl, .appWindows, .previousDesktop, .nextDesktop, .moveWindowPreviousDesktop, .moveWindowNextDesktop, .showDesktop, .hideApp, .hideOtherApps, .lockScreen]
    var shortcutSetupMessage: String? {
        guard self == .toggleStageManager else { return nil }
        return "Enable and assign “Turn Stage Manager on/off” in System Settings → Keyboard → Keyboard Shortcuts → Mission Control, then try again. Use a different combination from the Rotagivan keybinding that invokes this action."
    }

    /// Uses the current System Settings shortcut when present, then the macOS default.
    var macOSShortcut: RecordedShortcut? {
        resolvedMacOSShortcut(symbolicHotKeys: Self.symbolicHotKeys())
    }
    func resolvedMacOSShortcut(symbolicHotKeys: [String: Any]?) -> RecordedShortcut? {
        if self == .lockScreen {
            return RecordedShortcut(keyCode: 12, modifiers: UInt64((1 << 18) | (1 << 20)), keyLabel: "Q")
        }
        let command = UInt64(1 << 20), option = UInt64(1 << 19), shift = UInt64(1 << 17)
        switch self {
        case .toggleDock: return RecordedShortcut(keyCode: 2, modifiers: option | command, keyLabel: "D")
        case .previousApp: return RecordedShortcut(keyCode: 48, modifiers: command, keyLabel: "Tab")
        case .nextAppWindow: return RecordedShortcut(keyCode: 50, modifiers: command, keyLabel: "Backtick")
        case .previousAppWindow: return RecordedShortcut(keyCode: 50, modifiers: shift | command, keyLabel: "Backtick")
        case .hideApp: return RecordedShortcut(keyCode: 4, modifiers: command, keyLabel: "H")
        case .hideOtherApps: return RecordedShortcut(keyCode: 4, modifiers: option | command, keyLabel: "H")
        default: break
        }
        let ids: [Int]
        switch self {
        case .missionControl: ids = [32, 34]
        case .appExpose, .appWindows: ids = [33, 35]
        // Verified in Apple KeyboardSettings DefaultShortcutsTable.xml; no default key.
        case .toggleStageManager: ids = [222]
        case .previousDesktop: ids = [79, 80]
        case .nextDesktop: ids = [81, 82]
        case .showDesktop: ids = [36, 37]
        default: return nil
        }
        for id in ids {
            guard let entry = symbolicHotKeys?[String(id)] as? [String: Any],
                  (entry["enabled"] as? NSNumber)?.boolValue == true,
                  let value = entry["value"] as? [String: Any],
                  let parameters = value["parameters"] as? [NSNumber], parameters.count >= 3 else { continue }
            if self == .toggleStageManager {
                let key = parameters[1].doubleValue
                guard key.isFinite, key >= 0, key <= 127, key.rounded() == key else { continue }
            }
            let keyCode = UInt16(truncating: parameters[1])
            let modifiers = UInt64(truncating: parameters[2])
            let shortcut = RecordedShortcut(keyCode: keyCode, modifiers: modifiers, keyLabel: title)
            if shortcut.isPhysicalShortcut { return shortcut }
        }
        let control = UInt64(1 << 18)
        switch self {
        case .appExpose, .appWindows: return RecordedShortcut(keyCode: 125, modifiers: control, keyLabel: "Down Arrow")
        case .missionControl: return RecordedShortcut(keyCode: 126, modifiers: control, keyLabel: "Up Arrow")
        case .previousDesktop: return RecordedShortcut(keyCode: 123, modifiers: control, keyLabel: "Left Arrow")
        case .nextDesktop: return RecordedShortcut(keyCode: 124, modifiers: control, keyLabel: "Right Arrow")
        case .showDesktop: return RecordedShortcut(keyCode: 103, modifiers: 0, keyLabel: "F11")
        default: return nil
        }
    }
    private static func symbolicHotKeys() -> [String: Any]? {
        CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString,
                                  "com.apple.symbolichotkeys" as CFString) as? [String: Any]
    }
}

/// Explorer geometry is independent of the eight physical swipe bindings.
/// Existing saved direction strings keep exactly the same meaning.
struct ExplorerSlot: RawRepresentable, Codable, Hashable {
    let rawValue: String
    static let legacy: [Self] = [.up, .topRight, .right, .bottomRight, .down, .bottomLeft, .left, .topLeft]
    static let allCases = legacy
    static let up = Self(unchecked: "up"), topRight = Self(unchecked: "topRight"), right = Self(unchecked: "right"), bottomRight = Self(unchecked: "bottomRight")
    static let down = Self(unchecked: "down"), bottomLeft = Self(unchecked: "bottomLeft"), left = Self(unchecked: "left"), topLeft = Self(unchecked: "topLeft")
    private init(unchecked: String) { rawValue = unchecked }
    init(_ direction: SwipeDirection) { rawValue = direction.rawValue }
    init?(rawValue: String) {
        let isGenerated = rawValue.hasPrefix("angle") && Int(rawValue.dropFirst(5)).map { (0..<3600).contains($0) } == true
        guard Self.legacy.contains(where: { $0.rawValue == rawValue }) || isGenerated else { return nil }
        self.rawValue = rawValue
    }
    init(from decoder: Decoder) throws {
        let box = try decoder.singleValueContainer(), value = try box.decode(String.self)
        guard let slot = Self(rawValue: value) else { throw DecodingError.dataCorruptedError(in: box, debugDescription: "Invalid Explorer slot") }
        self = slot
    }
    func encode(to encoder: Encoder) throws { var box = encoder.singleValueContainer(); try box.encode(rawValue) }
    var angle: Double {
        if let index = Self.legacy.firstIndex(of: self) { return Double(index) * 45 - 90 }
        return Double(rawValue.dropFirst(5))! / 10 - 90
    }
    var swipeDirection: SwipeDirection? { SwipeDirection(rawValue: rawValue) }
    var title: String { swipeDirection?.title ?? "\(Int((angle + 90).rounded()))° clockwise" }
    static func slots(_ count: Int) -> [Self] {
        let count = (2...16).contains(count) ? count : 8
        return (0..<count).map { index in
            let tenths = index * 3600 / count
            return tenths % 450 == 0 ? legacy[tenths / 450] : Self(unchecked: "angle\(tenths)")
        }
    }
    static func classify(dx: Double, dy: Double, count: Int) -> Self? {
        guard dx.isFinite, dy.isFinite, dx != 0 || dy != 0 else { return nil }
        let slots = slots(count), angle = atan2(dy, dx) * 180 / .pi
        let ranked = slots.map { ($0, distance($0.angle, angle)) }.sorted { $0.1 < $1.1 }
        // Leave a small neutral seam, avoiding jitter on sector boundaries.
        return ranked[0].1 <= 180 / Double(slots.count) - 1.5 ? ranked[0].0 : nil
    }
    static func distance(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 360)
        return min(d, 360 - d)
    }
}

enum ExplorerLayerActivation: String, Codable, CaseIterable { case hold, toggle }
struct ExplorerWindowShortcut: Codable, Equatable {
    var command: AppExplorerAction
    var shortcut: RecordedShortcut
}
struct ExplorerWindowSettings: Codable, Equatable {
    var actionBindings: [ActionBinding]? = nil
    var layout: ExplorerWindowLayout = .halves
    var layers: [ExplorerHoldLayer] = []
    var shortcuts: [ExplorerWindowShortcut] = []
    var favorites: [AppExplorerFavorite]? = nil
    var slotCount: Int? = nil
}

/// Placement is independent of the gesture slot that launches it.
struct ExplorerWindowPlacement: Codable, Equatable {
    var direction: SwipeDirection
    var layout: ExplorerWindowLayout = .halves
    var title: String {
        if layout != .halves { return "\(direction.title) \(layout == .thirds ? "⅓" : layout == .fourths ? "¼" : "⅔")" }
        switch direction {
        case .left: return "Left half"
        case .right: return "Right half"
        case .up: return "Top half"
        case .down: return "Bottom half"
        case .topLeft: return "Top-left quarter"
        case .topRight: return "Top-right quarter"
        case .bottomLeft: return "Bottom-left quarter"
        case .bottomRight: return "Bottom-right quarter"
        }
    }
    static func tiles(layout: ExplorerWindowLayout) -> [AppExplorerFavorite] {
        SwipeDirection.allCases.map {
            let placement = Self(direction: $0, layout: layout)
            return AppExplorerFavorite(direction: ExplorerSlot($0), name: placement.title, windowPlacement: placement)
        }
    }
}

enum ExplorerTheme: String, Codable, CaseIterable {
    case native, starburst, starburstAir
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        if value == "vector" || value == "ember" { self = .starburstAir; return }
        guard let theme = Self(rawValue: value) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown HUD theme")
        }
        self = theme
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
    var title: String {
        switch self { case .native: return "Classic"; case .starburst: return "Starburst"; case .starburstAir: return "Starburst Air" }
    }
    var subtitle: String {
        switch self { case .native: return "Native · understated"; case .starburst: return "Radial · nested"; case .starburstAir: return "Glass · luminous" }
    }
    var isHUD: Bool { self != .native }
    var isRadial: Bool { self == .starburst || self == .starburstAir }
    var isFloating: Bool { self == .starburstAir }
}

enum ExplorerWindowLayout: String, Codable, CaseIterable {
    case halves, thirds, twoThirds, fourths
    var title: String { switch self { case .halves: return "Halves & quarters"; case .thirds: return "Thirds"; case .twoThirds: return "Two thirds"; case .fourths: return "Fourths (25%)" } }
    var fraction: Double { switch self { case .halves: return 0.5; case .thirds: return 1.0 / 3; case .twoThirds: return 2.0 / 3; case .fourths: return 0.25 } }
}

/// Templates copy ordinary editable tiles; they never regenerate after editing.
enum HUDLayerTemplate: String, CaseIterable, Identifiable {
    case macActions, mediaControls, editingActions
    var id: Self { self }
    var title: String {
        switch self {
        case .macActions: return "Mac Actions"
        case .mediaControls: return "Media Controls"
        case .editingActions: return "Editing Actions"
        }
    }
    var favorites: [AppExplorerFavorite] {
        switch self {
        case .mediaControls:
            return ExplorerMediaAction.allCases.compactMap { BindingAction.media($0).favorite(at: ExplorerSlot($0.direction)) }
        case .editingActions:
            return ExplorerReservedGroup.actions.tile(at: .up).children ?? []
        case .macActions:
            let commands: [(ExplorerSlot, AppExplorerAction)] = [
                (.up, .missionControl), (.topRight, .appWindows), (.right, .nextDesktop),
                (.bottomRight, .lockScreen), (.down, .previousApp), (.bottomLeft, .showDesktop),
                (.left, .previousDesktop), (.topLeft, .toggleStageManager)
            ]
            return commands.map { AppExplorerFavorite(direction: $0.0, name: $0.1.title, action: $0.1) }
        }
    }
}

enum HUDLayerBuiltIn: String, Codable, CaseIterable, Identifiable {
    case recentApps, actions, windowManager, mediaControls
    var id: Self { self }
    var title: String {
        switch self {
        case .recentApps: return "Recent Apps"
        case .actions: return "Actions"
        case .windowManager: return "Window Manager"
        case .mediaControls: return "Media Controls"
        }
    }
    var symbol: String {
        switch self {
        case .recentApps: return "clock.arrow.circlepath"
        case .actions: return "command"
        case .windowManager: return "rectangle.split.2x2"
        case .mediaControls: return "playpause.fill"
        }
    }
}

struct ExplorerHoldLayer: Codable, Equatable, Identifiable {
    var builtIn: HUDLayerBuiltIn? = nil
    // Legacy generated media layers expose their preset until the first edit
    // materializes it and clears builtIn. An intentionally empty custom layer stays empty.
    var editableFavorites: [AppExplorerFavorite] {
        builtIn == .mediaControls && favorites.isEmpty ? HUDLayerTemplate.mediaControls.favorites : favorites
    }

    var actionBindings: [ActionBinding]? = nil
    static func empty(name: String = "New layer") -> Self {
        Self(name: name, holdShortcut: nil, slotCount: 8, windowTilesConfigured: true)
    }
    var id = UUID()
    var name: String
    // Nil preserves older configs; the first four legacy layers receive open
    // cardinal positions in their existing order until the user arranges them.
    var position: HUDLayerPosition? = nil
    var holdShortcut: RecordedShortcut?
    var favorites: [AppExplorerFavorite] = []
    var windowLayout: ExplorerWindowLayout = .halves
    var slotCount: Int? = nil
    var activation: ExplorerLayerActivation? = nil
    var launchShortcut: RecordedShortcut? = nil
    var appBundleID: String? = nil
    var appName: String? = nil
    func isAvailable(in _: String?) -> Bool { true }
    // Old Window Manager layers generated their slots from windowLayout.
    // True distinguishes a deliberately empty custom grid from a legacy preset.
    var windowTilesConfigured: Bool? = nil
}

// Explorer-local keys never register globally or alter cursor/tap layers.
struct ExplorerHeldKeys {
    private var held: [(key: UInt16, id: UUID, modifiers: UInt64)] = []
    var activeID: UUID? { held.last?.id }
    mutating func press(key: UInt16, modifiers: UInt64, layers: [ExplorerHoldLayer]) -> Bool {
        if held.contains(where: { $0.key == key }) { return true }
        guard let layer = layers.first(where: { $0.holdShortcut?.keyCode == key && $0.holdShortcut?.modifiers == modifiers }) else { return false }
        held.append((key, layer.id, modifiers)); return true
    }
    mutating func release(key: UInt16) { held.removeAll { $0.key == key } }
    mutating func updateModifiers(_ flags: UInt64) { held.removeAll { $0.modifiers & flags != $0.modifiers } }
}

enum WebsiteIconCatalog {
    static let choices: [(symbol: String, title: String)] = [
        ("link", "Link"), ("book.closed.fill", "Reading"), ("doc.text.fill", "Document"),
        ("newspaper.fill", "News"), ("cart.fill", "Shopping"), ("play.rectangle.fill", "Video"),
        ("music.note", "Music"), ("message.fill", "Messages"), ("calendar", "Calendar"),
        ("chart.bar.fill", "Analytics"), ("star.fill", "Favorite"), ("heart.fill", "Personal"),
        ("briefcase.fill", "Work"), ("graduationcap.fill", "Learning"), ("cloud.fill", "Cloud")
    ]
    static let symbols = Set(choices.map(\.symbol))
}

struct AppExplorerFavorite: Codable, Equatable {
    var actionBindings: [ActionBinding]? = nil
    var direction: ExplorerSlot
    var bundleID: String? = nil
    var name: String
    var url: String? = nil
    // A portable SF Symbol override for web favorites. Nil discovers the site's favicon.
    var iconSymbol: String? = nil
    // A non-nil array is a named group, including an empty group.
    var children: [AppExplorerFavorite]? = nil
    // Optional so existing groups retain their manually assigned slots.
    var groupMode: AppExplorerMode? = nil
    var action: AppExplorerAction? = nil
    var shortcut: RecordedShortcut? = nil
    // A layer-local input that runs this tile's action while the tile is visible.
    // Unlike `shortcut`, this is an input trigger rather than the tile's output.
    var activationShortcut: RecordedShortcut? = nil
    // Nil inherits the enclosing Explorer's keys; [] explicitly has no layers.
    // Stored on the tile so layers follow renames, moves, swaps and copies.
    var holdLayers: [ExplorerHoldLayer]? = nil
    var slotCount: Int? = nil
    var showsWindows: Bool? = nil
    var windowPlacement: ExplorerWindowPlacement? = nil
    var supportsHoldLayers: Bool { isGroup || isWindowManager }
    var isWindowManager: Bool { action == .windowManager }
    var isGroup: Bool { children != nil }
    var hasPrimaryDestination: Bool {
        bundleID != nil || url != nil || action != nil || shortcut != nil || windowPlacement != nil
    }
    var hasDeepChoices: Bool { hasPrimaryDestination && children != nil && children?.isEmpty == false }
    var isPureGroup: Bool { isGroup && !hasPrimaryDestination }
    var isRecentGroup: Bool { isGroup && groupMode == .recent }

    var resolvedWebURL: URL? { url.flatMap(Self.webURL) }
    var isValidDestination: Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 512 else { return false }
        guard activationShortcut == nil || activationShortcut!.isValidHUDActionHotkey else { return false }
        guard iconSymbol == nil || (url != nil && WebsiteIconCatalog.symbols.contains(iconSymbol!)) else { return false }
        guard holdLayers == nil || supportsHoldLayers else { return false }
        guard slotCount == nil || ((isGroup || isWindowManager) && (2...16).contains(slotCount!)) else { return false }
        if windowPlacement != nil {
            return bundleID == nil && url == nil && groupMode == nil && action == nil && shortcut == nil && holdLayers == nil && showsWindows != true
        }
        guard showsWindows != true || (bundleID != nil && action == nil && !isGroup && url == nil && shortcut == nil) else { return false }
        if let shortcut {
            return shortcut.isValidExplorerShortcut && bundleID == nil && url == nil && groupMode == nil && action == nil
        }
        if action != nil { return bundleID == nil && url == nil && groupMode == nil }
        if isPureGroup { return bundleID == nil && url == nil }
        guard groupMode == nil else { return false }
        if url != nil { return bundleID == nil && resolvedWebURL != nil }
        guard let bundleID else { return false }
        return !bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && bundleID != "local.rotagivan"
    }

    /// Web links only: imported settings must not invoke file or custom URL handlers.
    static func webURL(_ value: String) -> URL? {
        guard value.count <= 4096, !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }),
              let parts = URLComponents(string: value),
              let scheme = parts.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil,
              parts.port.map({ (1...65535).contains($0) }) ?? true else { return nil }
        return parts.url
    }
}

struct AppExplorerSettings: Codable, Equatable {
    var actionBindings: [ActionBinding]? = nil
    static let recentDirections: [ExplorerSlot] = [.left, .topLeft, .up, .topRight, .right, .bottomRight, .down, .bottomLeft]
    static let maximumGroupDepth = 4
    static let maximumFavorites = 256
    // Kept only for lossless imports of older configurations. The root HUD is Favorites.
    var defaultMode: AppExplorerMode = .favorites
    var favorites: [AppExplorerFavorite] = []
    var holdShortcut: RecordedShortcut? // Retired root-mode shortcut; never registered.
    var holdLayers: [ExplorerHoldLayer]? = nil
    var theme: ExplorerTheme? = nil
    var animationsEnabled: Bool? = nil
    var centerCursorOnAppSwitch: Bool? = nil
    var slotCount: Int? = nil
    var windowManager: ExplorerWindowSettings? = nil
    var swipeDirection: HUDSwipeDirection? = nil
    var resolvedSwipeDirection: HUDSwipeDirection { swipeDirection ?? .inverted }
    var resolvedTheme: ExplorerTheme { theme ?? .starburstAir }
    var resolvedAnimationsEnabled: Bool { animationsEnabled ?? true }
    var resolvedCenterCursorOnAppSwitch: Bool { centerCursorOnAppSwitch ?? false }
    var resolvedHUDPositions: [UUID: HUDLayerPosition] {
        let layers = holdLayers ?? []
        var used = Set(layers.compactMap(\.position))
        var result = Dictionary(uniqueKeysWithValues: layers.compactMap { layer in
            layer.position.map { (layer.id, $0) }
        })
        for layer in layers where layer.position == nil {
            guard let position = HUDLayerPosition.legacyOrder.first(where: { !used.contains($0) }) else { continue }
            result[layer.id] = position
            used.insert(position)
        }
        return result
    }
    @discardableResult mutating func assignTemplate(_ template: HUDLayerTemplate, at position: HUDLayerPosition) -> UUID? {
        let positions = resolvedHUDPositions
        guard !positions.values.contains(position), (holdLayers ?? []).count < 128 else { return nil }
        var next = self
        var layers = next.holdLayers ?? []
        for index in layers.indices { layers[index].position = positions[layers[index].id] }
        var layer = ExplorerHoldLayer.empty(name: template.title)
        layer.position = position
        layer.favorites = template.favorites
        layers.append(layer)
        next.holdLayers = layers
        guard next.hasValidFavorites else { return nil }
        self = next
        return layer.id
    }

    /// Assign only into an empty position; never overwrite a user's saved HUD.
    @discardableResult mutating func assignBuiltIn(_ builtIn: HUDLayerBuiltIn, at position: HUDLayerPosition) -> UUID? {
        let positions = resolvedHUDPositions
        guard !positions.values.contains(position), (holdLayers ?? []).count < 128 else { return nil }
        var next = self
        var layers = next.holdLayers ?? []
        for index in layers.indices { layers[index].position = positions[layers[index].id] }
        var layer = ExplorerHoldLayer.empty(name: builtIn.title)
        layer.builtIn = builtIn
        layer.position = position
        if builtIn == .actions { layer.favorites = ExplorerReservedGroup.actions.tile(at: .up).children ?? [] }
        layers.append(layer)
        next.holdLayers = layers
        guard next.hasValidFavorites else { return nil }
        self = next
        return layer.id
    }

    /// The same fixed map drives the live HUD, keyboard navigation and settings preview.
    /// Imported layers beyond the eight map slots remain saved and shortcut-accessible.
    func hudMap(in bundleID: String? = nil, includingUnavailable: Bool = false) -> [HUDMapNode] {
        let positions = resolvedHUDPositions
        return [HUDMapNode(layerID: nil, name: "Main HUD", point: .zero,
            favorites: favorites, slotCount: slotCount ?? 8)] + (holdLayers ?? []).compactMap { layer in
            guard let position = positions[layer.id], includingUnavailable || layer.isAvailable(in: bundleID) else { return nil }
            return HUDMapNode(layerID: layer.id, name: layer.name, point: position.point,
                favorites: layer.builtIn == .windowManager ? windowEditor().favorites : layer.editableFavorites,
                slotCount: layer.builtIn == .windowManager ? windowEditor().count(at: []) : (layer.slotCount ?? slotCount ?? 8),
                builtIn: layer.builtIn)
        }
    }
    /// Present generated legacy window presets through the ordinary group editor.
    /// The first edit saves explicit slots; an empty saved array stays empty.
    func windowEditor(at path: [ExplorerSlot] = []) -> Self {
        let tile = path.isEmpty ? nil : favorite(at: path)
        let layout = windowManager?.layout ?? .halves
        let layers = tile?.holdLayers ?? windowManager?.layers ?? holdLayers ?? []
        let legacyExplorerLayers = tile?.holdLayers == nil && windowManager == nil
        // Inside the window applet, another Window Manager tile is an ordinary
        // nested group, not a recursive jump back to the shared applet root.
        func editableTiles(_ entries: [AppExplorerFavorite]) -> [AppExplorerFavorite] {
            entries.map { entry in
                var result = entry
                if entry.isWindowManager {
                    result.action = nil
                    result.children = entry.children ?? ExplorerWindowPlacement.tiles(layout: layout)
                    result.slotCount = entry.slotCount ?? 8
                }
                if let children = result.children { result.children = editableTiles(children) }
                result.holdLayers = result.holdLayers?.map { layer in
                    var updated = layer
                    let generated = entry.isWindowManager && layer.windowTilesConfigured != true && layer.favorites.isEmpty
                    updated.favorites = editableTiles(generated ? ExplorerWindowPlacement.tiles(layout: layer.windowLayout) : layer.favorites)
                    if entry.isWindowManager { updated.windowTilesConfigured = true }
                    return updated
                }
                return result
            }
        }
        return Self(actionBindings: tile?.actionBindings ?? windowManager?.actionBindings,
            favorites: editableTiles(tile?.children ?? windowManager?.favorites ?? ExplorerWindowPlacement.tiles(layout: layout)),
            holdShortcut: holdShortcut, holdLayers: layers.map { layer in
                var result = layer
                if layer.windowTilesConfigured != true && (layer.favorites.isEmpty || legacyExplorerLayers) {
                    result.favorites = ExplorerWindowPlacement.tiles(layout: layer.windowLayout)
                    result.slotCount = 8
                }
                result.windowTilesConfigured = true
                result.favorites = editableTiles(result.favorites)
                return result
            }, slotCount: tile?.slotCount ?? windowManager?.slotCount ?? 8)
    }

    @discardableResult mutating func saveWindowEditor(_ editor: Self, at path: [ExplorerSlot] = []) -> Bool {
        var next = self
        let layers = (editor.holdLayers ?? []).map { layer in
            var result = layer; result.windowTilesConfigured = true; return result
        }
        if let direction = path.last {
            guard var tile = favorite(at: path), tile.isWindowManager else { return false }
            tile.children = editor.favorites; tile.holdLayers = layers; tile.slotCount = editor.slotCount ?? 8
            tile.actionBindings = editor.actionBindings
            guard next.setFavorite(tile, at: direction, in: Array(path.dropLast())) else { return false }
        } else {
            var window = windowManager ?? ExplorerWindowSettings()
            window.favorites = editor.favorites; window.layers = layers; window.slotCount = editor.slotCount ?? 8
            window.actionBindings = editor.actionBindings
            next.windowManager = window
        }
        guard next.hasValidFavorites else { return false }
        self = next
        return true
    }
    func projected(layerID: UUID?) -> Self {
        guard let layer = holdLayers?.first(where: { $0.id == layerID }) else { return self }
        var result = self
        result.favorites = layer.editableFavorites
        result.actionBindings = layer.actionBindings
        result.defaultMode = .favorites
        result.holdLayers = nil
        result.slotCount = layer.slotCount ?? slotCount
        return result
    }
    func mode(holdingShortcut: Bool) -> AppExplorerMode { .favorites }
    func favorites(at path: [ExplorerSlot]) -> [AppExplorerFavorite]? {
        var current = favorites
        for (index, direction) in path.enumerated() {
            guard let group = current.first(where: { $0.direction == direction }),
                  let children = group.children else { return nil }
            if group.isRecentGroup { return index == path.count - 1 ? [] : nil }
            current = children
        }
        return current
    }
    func favorite(at path: [ExplorerSlot]) -> AppExplorerFavorite? {
        guard let direction = path.last else { return nil }
        return favorites(at: Array(path.dropLast()))?.first { $0.direction == direction }
    }
    func layers(at path: [ExplorerSlot]) -> [ExplorerHoldLayer] {
        path.isEmpty ? (holdLayers ?? []) : (favorite(at: path)?.holdLayers ?? [])
    }
    func count(at path: [ExplorerSlot]) -> Int { path.isEmpty ? (slotCount ?? 8) : (favorite(at: path)?.slotCount ?? 8) }
    @discardableResult mutating func resize(to count: Int, at path: [ExplorerSlot]) -> Bool {
        guard (2...16).contains(count),
              let old = path.isEmpty ? favorites : favorite(at: path)?.children, old.count <= count else { return false }
        var available = ExplorerSlot.slots(count), placed: [AppExplorerFavorite] = []
        // Keep exact positions first, then place remaining tiles in the closest free sector.
        for entry in old.sorted(by: { available.contains($0.direction) && !available.contains($1.direction) }) {
            guard let index = available.indices.min(by: {
                ExplorerSlot.distance(available[$0].angle, entry.direction.angle) < ExplorerSlot.distance(available[$1].angle, entry.direction.angle)
            }) else { return false }
            var moved = entry; moved.direction = available.remove(at: index); placed.append(moved)
        }
        func preserveLayerCounts(_ layers: [ExplorerHoldLayer]?, previous: Int) -> [ExplorerHoldLayer]? {
            layers?.map { layer in var copy = layer; copy.slotCount = layer.slotCount ?? previous; return copy }
        }
        if path.isEmpty {
            holdLayers = preserveLayerCounts(holdLayers, previous: slotCount ?? 8)
            favorites = placed; slotCount = count
        }
        else if var group = favorite(at: path), let direction = path.last {
            group.holdLayers = preserveLayerCounts(group.holdLayers, previous: group.slotCount ?? 8)
            group.children = placed; group.slotCount = count
            return setFavorite(group, at: direction, in: Array(path.dropLast()))
        } else { return false }
        return true
    }
    func layerScope(at path: [ExplorerSlot]) -> [ExplorerSlot] {
        for length in stride(from: path.count, through: 1, by: -1) {
            let prefix = Array(path.prefix(length))
            if favorite(at: prefix)?.holdLayers != nil { return prefix }
        }
        return []
    }
    /// Runtime projection retains definitions so another key at the same
    /// scope can temporarily replace this layer, then return on key release.
    func applying(_ layer: ExplorerHoldLayer, at path: [ExplorerSlot]) -> Self {
        var next = self
        if path.isEmpty {
            next.favorites = layer.editableFavorites
            next.actionBindings = layer.actionBindings
            next.defaultMode = .favorites
            next.slotCount = layer.slotCount ?? slotCount
        } else if var tile = favorite(at: path), tile.isGroup, let direction = path.last {
            tile.children = layer.favorites
            tile.actionBindings = layer.actionBindings
            tile.groupMode = .favorites
            tile.slotCount = layer.slotCount ?? tile.slotCount
            next.setFavorite(tile, at: direction, in: Array(path.dropLast()))
        }
        return next
    }
    var hasValidFavorites: Bool {
        guard slotCount == nil || (2...16).contains(slotCount!) else { return false }
        var remaining = Self.maximumFavorites
        var remainingLayers = 128
        let windowCommandKeys = windowManager?.shortcuts.map(\.shortcut) ?? []
        func validLayers(_ layers: [ExplorerHoldLayer], depth: Int, groupDepth: Int, count: Int = 8,
                         commandKeys: [RecordedShortcut] = []) -> Bool {
            guard depth <= 12, layers.count <= 16, Set(layers.map(\.id)).count == layers.count,
                  Set(layers.compactMap(\.position)).count == layers.compactMap(\.position).count else { return false }
            var keys = Set<String>()
            for layer in layers {
                remainingLayers -= 1
                guard remainingLayers >= 0, !layer.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      layer.name.count <= 128, layer.slotCount == nil || (2...16).contains(layer.slotCount!) else { return false }
                if let key = layer.holdShortcut {
                    guard key.isPhysicalShortcut, key.keyCode != 53,
                          keys.insert("\(key.keyCode):\(key.modifiers)").inserted else { return false }
                }
                if let key = layer.launchShortcut, !key.isPhysicalShortcut || key.keyCode == 53 || (key.keyCode < 64 && key.modifiers == 0) { return false }
                if let app = layer.appBundleID, app.isEmpty || app.count > 512 { return false }
                guard valid(layer.favorites, depth: groupDepth, nesting: depth + 1, count: layer.slotCount ?? count,
                    bindings: layer.actionBindings ?? [], reserved: layers.compactMap(\.holdShortcut) + commandKeys,
                    commandKeys: commandKeys) else { return false }
            }
            return true
        }
        func valid(_ entries: [AppExplorerFavorite], depth: Int, nesting: Int = 0, count: Int = 8,
                   bindings: [ActionBinding] = [], reserved: [RecordedShortcut] = [],
                   commandKeys: [RecordedShortcut] = []) -> Bool {
            guard bindings.isValidBindings(reservedKeys: entries.compactMap(\.activationShortcut) + reserved) else { return false }
            guard (2...16).contains(count), depth <= Self.maximumGroupDepth, nesting <= 12, entries.count <= count,
                  entries.allSatisfy({ ExplorerSlot.slots(count).contains($0.direction) }),
                  Set(entries.map(\.direction)).count == entries.count else { return false }
            var actionHotkeys = Set<String>()
            for entry in entries {
                remaining -= 1
                guard remaining >= 0, entry.isValidDestination else { return false }
                if let key = entry.activationShortcut,
                   !actionHotkeys.insert(key.identity).inserted { return false }
                if let children = entry.children, !valid(children, depth: depth + 1, nesting: nesting + 1,
                    count: entry.slotCount ?? 8, bindings: entry.actionBindings ?? [],
                    reserved: entry.holdLayers.map { $0.compactMap(\.holdShortcut) + commandKeys } ?? reserved,
                    commandKeys: commandKeys) { return false }
                if entry.children == nil && !(entry.actionBindings ?? []).isValidBindings(
                    reservedKeys: entry.isWindowManager ? (entry.holdLayers ?? []).compactMap(\.holdShortcut) + windowCommandKeys : []) { return false }
                if let layers = entry.holdLayers {
                    guard validLayers(layers, depth: nesting + 1, groupDepth: entry.isGroup ? depth + 1 : depth,
                        count: entry.slotCount ?? 8, commandKeys: entry.isWindowManager ? windowCommandKeys : commandKeys) else { return false }
                }
            }
            return true
        }
        if let windowManager {
            guard valid(windowManager.favorites ?? [], depth: 0, count: windowManager.slotCount ?? 8,
                        bindings: windowManager.actionBindings ?? [], reserved: windowManager.layers.compactMap(\.holdShortcut) + windowCommandKeys,
                        commandKeys: windowCommandKeys),
                  validLayers(windowManager.layers, depth: 0, groupDepth: 0, count: windowManager.slotCount ?? 8,
                              commandKeys: windowCommandKeys) else { return false }
            var keys = Set(windowManager.layers.compactMap { $0.holdShortcut }.map { "\($0.keyCode):\($0.modifiers)" })
            var commands = Set<AppExplorerAction>()
            for binding in windowManager.shortcuts {
                let key = binding.shortcut
                guard AppExplorerAction.windowCommands.contains(binding.command), commands.insert(binding.command).inserted,
                      key.isPhysicalShortcut, key.keyCode != 53,
                      keys.insert("\(key.keyCode):\(key.modifiers)").inserted else { return false }
            }
        }
        return validLayers(holdLayers ?? [], depth: 0, groupDepth: 0, count: slotCount ?? 8) &&
            valid(favorites, depth: 0, count: slotCount ?? 8, bindings: actionBindings ?? [],
                  reserved: (holdLayers ?? []).compactMap(\.holdShortcut))
    }
    @discardableResult
    mutating func swapFavorites(from source: ExplorerSlot, to destination: ExplorerSlot,
                                in path: [ExplorerSlot] = []) -> Bool {
        guard source != destination, hasValidFavorites,
              let slots = favorites(at: path),
              let moving = slots.first(where: { $0.direction == source }) else { return false }
        let displaced = slots.first { $0.direction == destination }
        var next = self
        guard next.setFavorite(moving, at: destination, in: path),
              next.setFavorite(displaced, at: source, in: path), next.hasValidFavorites else { return false }
        self = next
        return true
    }

    @discardableResult
    mutating func setFavorite(_ favorite: AppExplorerFavorite?, at direction: ExplorerSlot, in path: [ExplorerSlot] = []) -> Bool {
        func replace(_ entries: inout [AppExplorerFavorite], path: ArraySlice<ExplorerSlot>) -> Bool {
            if let head = path.first {
                guard let index = entries.firstIndex(where: { $0.direction == head }),
                      !entries[index].isRecentGroup,
                      var children = entries[index].children else { return false }
                guard replace(&children, path: path.dropFirst()) else { return false }
                entries[index].children = children
            } else {
                entries.removeAll { $0.direction == direction }
                if var favorite { favorite.direction = direction; entries.append(favorite) }
            }
            return true
        }
        return replace(&favorites, path: path[...])
    }
}

/// A structural address, not a runtime projection: local layers and root layers
/// remain distinct even when they use the same shortcut or name.
enum ExplorerTilePathStep: Hashable {
    case group(ExplorerSlot)
    case layer(UUID)
    var token: String {
        switch self { case .group(let slot): return "g:" + slot.rawValue; case .layer(let id): return "l:" + id.uuidString }
    }
    init?(token: String) {
        if token.hasPrefix("g:"), let slot = ExplorerSlot(rawValue: String(token.dropFirst(2))) { self = .group(slot) }
        else if token.hasPrefix("l:"), let id = UUID(uuidString: String(token.dropFirst(2))) { self = .layer(id) }
        else { return nil }
    }
}

struct ExplorerTileContainer: Identifiable {
    let id: [ExplorerTilePathStep]
    let title: String
    let count: Int
    let favorites: [AppExplorerFavorite]
}

/// Navigation targets are separate from editable tile-transfer destinations.
/// A window owner of [] denotes the standalone Window Manager; nil denotes
/// App Explorer. A nonempty owner ends at a Window Manager tile.
struct HUDActionDestination: Identifiable {
    let path: [ExplorerTilePathStep]
    let windowOwnerPath: [ExplorerTilePathStep]?
    let title: String
    var id: String {
        (windowOwnerPath.map { "window:" + $0.map(\.token).joined(separator: "/") } ?? "explorer") +
            "|" + path.map(\.token).joined(separator: "/")
    }
}

extension AppExplorerSettings {
    /// All editable grids, including alternate layers belonging to nested groups.
    /// Recent-app grids and Window Manager layouts are generated, not destinations.
    func tileContainers(rootTitle: String = "Favorites", includeRecent: Bool = false) -> [ExplorerTileContainer] {
        guard hasValidFavorites else { return [] }
        var result: [ExplorerTileContainer] = []
        func visit(_ entries: [AppExplorerFavorite], layers: [ExplorerHoldLayer]?, count: Int,
                   path: [ExplorerTilePathStep], title: String, editable: Bool = true) {
            if editable || includeRecent {
                result.append(ExplorerTileContainer(id: path, title: title, count: count, favorites: entries))
            }
            if editable {
                for tile in entries where tile.isGroup {
                    visit(tile.children ?? [], layers: tile.holdLayers, count: tile.slotCount ?? 8,
                          path: path + [.group(tile.direction)], title: "\(title) › \(tile.name) (\(tile.direction.title))",
                          editable: !tile.isRecentGroup)
                }
            }
            for layer in layers ?? [] {
                visit(layer.favorites, layers: nil, count: layer.slotCount ?? count,
                      path: path + [.layer(layer.id)], title: "\(title) › Layer: \(layer.name)")
            }
        }
        visit(favorites, layers: holdLayers, count: slotCount ?? 8, path: [], title: rootTitle)
        return result
    }

    func windowActionSettings(ownerPath: [ExplorerTilePathStep]) -> AppExplorerSettings? {
        if ownerPath.isEmpty { return windowEditor() }
        guard case .group(let slot)? = ownerPath.last else { return nil }
        var held = ExplorerScopedHeldKeys()
        guard let groups = held.selectContainer(Array(ownerPath.dropLast()), settings: self) else { return nil }
        let resolved = held.resolved(self)
        let owner = groups + [slot]
        guard resolved.favorite(at: owner)?.isWindowManager == true else { return nil }
        return resolved.windowEditor(at: owner)
    }

    func hudActionDestinations() -> [HUDActionDestination] {
        let explorer = tileContainers(rootTitle: "Main HUD", includeRecent: true)
        var result = explorer.map { HUDActionDestination(path: $0.id, windowOwnerPath: nil, title: $0.title) }
        func appendWindow(owner: [ExplorerTilePathStep], title: String) {
            guard let window = windowActionSettings(ownerPath: owner) else { return }
            result += window.tileContainers(rootTitle: title, includeRecent: true).map {
                HUDActionDestination(path: $0.id, windowOwnerPath: owner, title: $0.title)
            }
        }
        appendWindow(owner: [], title: "Window Manager")
        for container in explorer {
            for tile in container.favorites where tile.isWindowManager {
                appendWindow(owner: container.id + [.group(tile.direction)], title: container.title + " › " + tile.name)
            }
        }
        return result
    }

    func containsHUDActionTarget(_ action: BindingAction) -> Bool {
        guard action.kind == .hudLayer, action.isValid else { return false }
        if let id = action.hudLayerID { return (holdLayers ?? []).contains { $0.id == id } }
        var targetSettings = self
        if let owner = action.windowOwnerPath {
            let path = owner.compactMap(ExplorerTilePathStep.init(token:))
            guard path.count == owner.count, let window = windowActionSettings(ownerPath: path) else { return false }
            targetSettings = window
        }
        let tokens = action.hudPath ?? []
        let path = tokens.compactMap(ExplorerTilePathStep.init(token:))
        var held = ExplorerScopedHeldKeys()
        return path.count == tokens.count && held.selectContainer(path, settings: targetSettings) != nil
    }

    fileprivate mutating func writeTile(_ tile: AppExplorerFavorite?, at slot: ExplorerSlot,
                                        container: [ExplorerTilePathStep]) -> Bool {
        func replace(_ entries: inout [AppExplorerFavorite], layers: inout [ExplorerHoldLayer]?,
                     path: ArraySlice<ExplorerTilePathStep>) -> Bool {
            guard let step = path.first else {
                entries.removeAll { $0.direction == slot }
                if var tile { tile.direction = slot; entries.append(tile) }
                return true
            }
            switch step {
            case .group(let direction):
                guard let index = entries.firstIndex(where: { $0.direction == direction && $0.isGroup }),
                      var children = entries[index].children else { return false }
                var childLayers = entries[index].holdLayers
                guard replace(&children, layers: &childLayers, path: path.dropFirst()) else { return false }
                entries[index].children = children
                entries[index].holdLayers = childLayers
            case .layer(let id):
                guard var updated = layers, let index = updated.firstIndex(where: { $0.id == id }) else { return false }
                var noLayers: [ExplorerHoldLayer]?
                guard replace(&updated[index].favorites, layers: &noLayers, path: path.dropFirst()) else { return false }
                layers = updated
            }
            return true
        }
        return replace(&favorites, layers: &holdLayers, path: container[...])
    }
}

/// Snapshot-bound transaction: a synced edit must never move the wrong tile.
struct ExplorerTileTransfer: Identifiable {
    let id = UUID()
    let snapshot: AppExplorerSettings
    let source: [ExplorerTilePathStep]
    let slot: ExplorerSlot
    var favorite: AppExplorerFavorite? {
        snapshot.tileContainers().first { $0.id == source }?.favorites.first { $0.direction == slot }
    }

    /// Returns an actionable error, or nil after an atomic, lossless commit.
    func apply(to destination: [ExplorerTilePathStep], slot target: ExplorerSlot,
               copy: Bool, settings: inout AppExplorerSettings) -> String? {
        guard settings == snapshot else { return "The Explorer changed while this window was open. Cancel and reopen Move or copy." }
        guard let moving = favorite,
              let container = snapshot.tileContainers().first(where: { $0.id == destination }),
              ExplorerSlot.slots(container.count).contains(target) else { return "That tile or destination is no longer available." }
        guard source != destination || slot != target else { return "Choose a different slot." }
        let sourceTile = source + [.group(slot)]
        let destinationTile = destination + [.group(target)]
        guard !destination.starts(with: sourceTile), !source.starts(with: destinationTile) else {
            return "A HUD layer cannot be moved or copied into itself, or swapped with an enclosing HUD layer."
        }
        let displaced = container.favorites.first { $0.direction == target }
        guard !copy || displaced == nil else { return "Choose an empty slot for a copy. Move swaps occupied slots without deleting either tile." }
        var next = settings
        guard next.writeTile(moving, at: target, container: destination),
              copy || next.writeTile(displaced, at: slot, container: source), next.hasValidFavorites else {
            return "This would exceed the nested HUD-layer, tile, or custom-layer limits. Nothing was changed."
        }
        settings = next
        return nil
    }
}

/// Presses retain the scope in which they began. Projection is recomputed from
/// saved settings on release, so child layers never overwrite parent/sibling tiles.
struct ExplorerScopedHeldKeys {
    private struct Press {
        let key: UInt16
        let modifiers: UInt64
        let id: UUID
        let scope: [ExplorerSlot]
        let toggled: Bool
    }
    private var held: [Press] = []
    var activeID: UUID? { held.last?.id }
    var activeScope: [ExplorerSlot]? { held.last?.scope }
    @discardableResult mutating func selectRootLayer(_ id: UUID, settings: AppExplorerSettings) -> Bool {
        guard settings.holdLayers?.contains(where: { $0.id == id }) == true else { return false }
        held = [Press(key: UInt16.max, modifiers: 0, id: id, scope: [], toggled: true)]
        return true
    }
    /// Select nested layer/group addresses atomically, without inventing an
    /// activation key or overwriting the saved configuration.
    mutating func selectContainer(_ path: [ExplorerTilePathStep], settings: AppExplorerSettings) -> [ExplorerSlot]? {
        guard path.count <= 16 else { return nil }
        var next = Self()
        var current = settings
        var groups: [ExplorerSlot] = []
        for step in path {
            switch step {
            case .group(let slot):
                let target = groups + [slot]
                guard current.favorite(at: target)?.isGroup == true else { return nil }
                groups = target
            case .layer(let id):
                guard let layer = current.layers(at: groups).first(where: { $0.id == id }) else { return nil }
                next.held.append(Press(key: UInt16.max, modifiers: 0, id: id, scope: groups, toggled: true))
                current = current.applying(layer, at: groups)
            }
        }
        self = next
        return groups
    }
    func resolved(_ original: AppExplorerSettings) -> AppExplorerSettings {
        held.reduce(original) { settings, press in
            guard let layer = settings.layers(at: press.scope).first(where: { $0.id == press.id }) else { return settings }
            return settings.applying(layer, at: press.scope)
        }
    }
    func activeLayer(at path: [ExplorerSlot], in original: AppExplorerSettings) -> ExplorerHoldLayer? {
        var settings = original
        var active: ExplorerHoldLayer?
        for press in held {
            guard let layer = settings.layers(at: press.scope).first(where: { $0.id == press.id }) else { continue }
            if path.starts(with: press.scope) { active = layer }
            settings = settings.applying(layer, at: press.scope)
        }
        return active
    }
    mutating func press(key: UInt16, modifiers: UInt64, path: [ExplorerSlot], settings: AppExplorerSettings, bundleID: String? = nil) -> Bool {
        if let existing = held.first(where: { $0.key == key }) {
            if existing.toggled { held.removeAll { $0.key == key } }
            return true
        }
        let current = resolved(settings)
        let scope = current.layerScope(at: path)
        guard let layer = current.layers(at: scope).first(where: {
            $0.holdShortcut?.keyCode == key && $0.holdShortcut?.modifiers == modifiers && $0.isAvailable(in: bundleID)
        }) else { return false }
        held.append(Press(key: key, modifiers: modifiers, id: layer.id, scope: scope, toggled: layer.activation == .toggle))
        return true
    }
    mutating func release(key: UInt16) { held.removeAll { $0.key == key && !$0.toggled } }
    mutating func updateModifiers(_ flags: UInt64) { held.removeAll { !$0.toggled && $0.modifiers & flags != $0.modifiers } }
    mutating func leave(to path: [ExplorerSlot]) { held.removeAll { !path.starts(with: $0.scope) } }
    mutating func reconcile(_ original: AppExplorerSettings) {
        var current = original
        held = held.filter { press in
            guard let layer = current.layers(at: press.scope).first(where: { $0.id == press.id }) else { return false }
            current = current.applying(layer, at: press.scope)
            return true
        }
    }
}

// A drag is local to one grid and one settings snapshot. A sync or edit during
// the gesture must not move a different app that happens to occupy that slot.
struct ExplorerSlotDrag {
    let source: ExplorerSlot
    let path: [ExplorerSlot]
    let snapshot: AppExplorerSettings

    init?(source: ExplorerSlot, path: [ExplorerSlot], settings: AppExplorerSettings) {
        guard settings.hasValidFavorites,
              settings.favorites(at: path)?.contains(where: { $0.direction == source }) == true else { return nil }
        self.source = source; self.path = path; self.snapshot = settings
    }

    func apply(to destination: ExplorerSlot, in currentPath: [ExplorerSlot], settings: inout AppExplorerSettings) -> Bool {
        guard currentPath == path, settings == snapshot else { return false }
        return settings.swapFavorites(from: source, to: destination, in: path)
    }
}

enum AppVersion {
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development" }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—" }
    static var display: String { "v\(version) (\(build))" }
}

/// User-facing settings are always 0...100. MotionProfile keeps the values
/// used by the gesture engine so existing saved profiles retain their feel.
enum SettingsScale {
    case cursorGain
    case linear(minimum: Double, maximum: Double)
    case momentum(maximum: Double)
    case centered(minimum: Double, maximum: Double, baseline: Double)

    func percentage(for value: Double) -> Double {
        switch self {
        case .cursorGain: return CursorSpeedScale.percent(forGain: value)
        case let .linear(minimum, maximum):
            guard maximum > minimum else { return 0 }
            return min(100, max(0, (value - minimum) / (maximum - minimum) * 100))
        case let .momentum(maximum):
            guard value > 0 else { return 0 }
            guard maximum > 0 else { return 0 }
            let normalized = min(1, max(0, (value / maximum - 0.70) / 0.30))
            return min(100, max(0, (1 - sqrt(1 - normalized)) * 100))
        case let .centered(minimum, maximum, baseline):
            let base = min(maximum, max(minimum, baseline))
            guard base > minimum else { return value <= minimum ? 50 : 100 }
            if value <= base { return min(50, max(0, (value - minimum) / (base - minimum) * 50)) }
            guard maximum > base else { return 50 }
            return min(100, max(50, 50 + (value - base) / (maximum - base) * 50))
        }
    }

    func value(for percentage: Double) -> Double {
        let p = min(100, max(0, percentage)) / 100
        switch self {
        case .cursorGain: return CursorSpeedScale.gain(forPercent: percentage)
        case let .linear(minimum, maximum): return minimum + (maximum - minimum) * p
        case let .momentum(maximum): return p == 0 ? 0 : maximum * (0.70 + 0.30 * (1 - pow(1 - p, 2)))
        case let .centered(minimum, maximum, baseline):
            let base = min(maximum, max(minimum, baseline))
            if p <= 0.5 { return minimum + (base - minimum) * (p * 2) }
            return base + (maximum - base) * ((p - 0.5) * 2)
        }
    }
}

/// Fixed engine bounds behind the simple 0...100 profile controls.
enum ProfileMaximum {
    // Keep the profile scale practical: 100 is a fast but controllable cursor.
    static let cursorSpeed = 2.4
    // 1.0 is linear tracking; 1.4 is deliberately the practical upper bound.
    // Higher exponents make ordinary cursor motion feel disproportionately fast.
    static let cursorAcceleration = 1.4
    // Acceleration begins only after deliberate, faster finger movement.
    static let cursorAccelerationOnset = 6.0
    // Navigator reports are high-resolution contact coordinates. A few
    // thousand units/sec separates deliberate fast movement from precise
    // small movement; 800 made nearly every movement appear "Fast".
    static let cursorSpeedTransition = 4_000.0
    // Cursor falloff is intentionally brief; unlike scroll coasting, it never
    // permits a continuously gliding cursor.
    static let cursorFalloff = 0.85
    static let scrollSpeed = 6.0
    static let scrollAcceleration = 1.5
    static let scrollAccelerationOnset = 250.0
    static let coastCoefficient = 1.0
    static let tapDuration = 1.0
    static let tapMovement = 160.0
    static let regripWindow = 2.0
}

enum TapAction: String, Codable, CaseIterable {
    case optionF19, enter, leftClick, doubleLeftClick, tripleLeftClick, rightClick, none, shortcut, appExplorer, windowManager
    var title: String {
        switch self {
        case .optionF19: return "Option + F19"
        case .enter: return "Enter"
        case .leftClick: return "Left click"
        case .doubleLeftClick: return "Double left click"
        case .tripleLeftClick: return "Triple left click"
        case .rightClick: return "Right click"
        case .none: return "Nothing"
        case .shortcut: return "Keyboard shortcut"
        case .appExplorer: return "HUD"
        case .windowManager: return "Window Manager"
        }
    }

    /// A tap-and-hold drag starts with a real left mouse down, so it can only
    /// follow a one-finger tap that also acts as a left click.
    var supportsTapAndHoldDrag: Bool { self == .leftClick }
}

struct RecordedShortcut: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: UInt64
    var keyLabel: String
    // Stable action references share the existing tap/swipe payload slot. They
    // are never posted or registered as physical keyboard events.
    var macroID: String? = nil
    var hudLayerID: UUID? = nil
    var assignedAction: BindingAction? = nil
    static func assigned(_ action: BindingAction) -> Self {
        Self(keyCode: 0, modifiers: 0, keyLabel: String(action.title.prefix(128)), assignedAction: action)
    }
    var isActionReference: Bool { macroID != nil || hudLayerID != nil || assignedAction != nil }
    static func macro(_ entry: NamedHotkey) -> Self { Self(keyCode: 0, modifiers: 0, keyLabel: entry.name, macroID: entry.id) }
    static func hudLayer(_ layer: ExplorerHoldLayer) -> Self { Self(keyCode: 0, modifiers: 0, keyLabel: layer.name, hudLayerID: layer.id) }
    /// Labels do not participate in key identity (keyboard layouts can rename a key).
    var identity: String { assignedAction.map { "action:\($0.identity)" } ?? macroID.map { "macro:\($0)" } ?? hudLayerID.map { "hud:\($0)" } ?? "\(keyCode):\(modifiers & 0x1e0000)" }
    var readableCombination: String {
        if let assignedAction { return assignedAction.title }
        if isActionReference { return hudLayerID == nil ? "Macro: \(keyLabel)" : "HUD layer: \(keyLabel)" }
        let parts = [(UInt64(1 << 20), "Cmd"), (1 << 18, "Ctrl"), (1 << 19, "Option"), (1 << 17, "Shift")]
        return (parts.compactMap { modifiers & $0.0 != 0 ? $0.1 : nil } + [keyLabel]).joined(separator: "+")
    }
    var isValidExplorerShortcut: Bool {
        if let assignedAction {
            return macroID == nil && hudLayerID == nil && keyCode == 0 && modifiers == 0 &&
                !keyLabel.isEmpty && keyLabel.count <= 128 && assignedAction.isValid
        }
        if isActionReference {
            return (macroID == nil || hudLayerID == nil) && keyCode == 0 && modifiers == 0 &&
                (macroID.map { !$0.isEmpty && $0.count <= 128 } ?? true) && !keyLabel.isEmpty && keyLabel.count <= 128
        }
        return isPhysicalShortcut
    }
    var isPhysicalShortcut: Bool {
        let allowedModifiers: UInt64 = (1 << 17) | (1 << 18) | (1 << 19) | (1 << 20)
        return !isActionReference && keyCode <= 127 && modifiers & ~allowedModifiers == 0 &&
            !keyLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && keyLabel.count <= 128 &&
            !keyLabel.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
    /// Carbon can register bare function/special keys. Letter and number keys
    /// need a modifier so normal typing is never captured globally.
    var isValidGlobalHotkey: Bool {
        isPhysicalShortcut && keyCode != 53 && (keyCode >= 64 || modifiers & 0x1e0000 != 0)
    }
    /// Escape closes the HUD; bare E/S remain its persistent controls.
    var isValidHUDActionHotkey: Bool {
        isPhysicalShortcut && keyCode != 53 && !(modifiers & 0x1e0000 == 0 && (keyCode == 1 || keyCode == 14))
    }
}

struct MacroStep: Codable, Equatable {
    enum Kind: String, Codable { case keystroke, openApp }
    var kind: Kind
    var shortcut: RecordedShortcut? = nil
    var bundleID: String? = nil
    var appName: String? = nil
    static func key(_ shortcut: RecordedShortcut) -> Self { Self(kind: .keystroke, shortcut: shortcut) }
    static func app(bundleID: String, name: String) -> Self { Self(kind: .openApp, bundleID: bundleID, appName: name) }
    var title: String { kind == .keystroke ? shortcut?.readableCombination ?? "Missing keystroke" : "Open \(appName ?? bundleID ?? "app")" }
    var isValid: Bool {
        switch kind {
        case .keystroke: return shortcut?.isPhysicalShortcut == true && bundleID == nil && appName == nil
        case .openApp:
            guard shortcut == nil, let bundleID, !bundleID.isEmpty, bundleID.count <= 255,
                  bundleID != "local.rotagivan", bundleID.contains("."),
                  bundleID.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-").contains($0) }),
                  let appName, !appName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, appName.count <= 128,
                  !appName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return false }
            return true
        }
    }
}

struct NamedHotkey: Codable, Equatable, Identifiable {
    var id: String = UUID().uuidString
    var name: String
    var shortcut: RecordedShortcut
    var steps: [RecordedShortcut]? = nil
    var stepDelayMilliseconds: Int? = nil
    var sequence: [MacroStep]? = nil
    /// Optional registered input that runs this saved action from anywhere.
    /// Kept separate from `shortcut`, which is the legacy first output step.
    var activationShortcut: RecordedShortcut? = nil
    var resolvedSteps: [RecordedShortcut] { steps ?? [shortcut] }
    var resolvedSequence: [MacroStep] { sequence ?? resolvedSteps.map(MacroStep.key) }
    var resolvedDelay: Int { stepDelayMilliseconds ?? 100 }
    var summary: String { resolvedSequence.map(\.title).joined(separator: " → ") }
    var isValid: Bool {
        !id.isEmpty && id.count <= 128 && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        name.count <= 120 && !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) && shortcut.isPhysicalShortcut &&
        !resolvedSequence.isEmpty && resolvedSequence.count <= 32 && resolvedSequence.allSatisfy(\.isValid) &&
        (sequence == nil || steps == nil) && (activationShortcut?.isValidGlobalHotkey ?? true) &&
        (0...2000).contains(resolvedDelay)
    }
}

extension Array where Element == NamedHotkey {
    func label(for shortcut: RecordedShortcut) -> String? {
        if let id = shortcut.macroID ?? shortcut.assignedAction?.macroID { return first { $0.id == id }?.name }
        return first { $0.resolvedSequence.count == 1 && $0.resolvedSequence.first?.shortcut?.identity == shortcut.identity }?.name
    }
    func title(for shortcut: RecordedShortcut) -> String {
        if let action = shortcut.assignedAction { return title(for: action) }
        if let id = shortcut.macroID { return first { $0.id == id }.map { "\($0.name) (\($0.summary))" } ?? "Missing macro: \(shortcut.keyLabel)" }
        return label(for: shortcut).map { "\($0) (\(shortcut.readableCombination))" } ?? shortcut.readableCombination
    }
    func title(for action: BindingAction) -> String {
        if let id = action.macroID {
            return first { $0.id == id }.map { "\($0.name) (\($0.summary))" } ?? "Missing macro: \(action.name ?? "Saved action")"
        }
        return action.title
    }
    var isValidDictionary: Bool {
        let triggers = compactMap(\.activationShortcut)
        return count <= 500 && allSatisfy(\.isValid) && Set(map(\.id)).count == count &&
        Set(triggers.map(\.identity)).count == triggers.count &&
        Set(filter { $0.steps == nil && $0.sequence == nil }.map { $0.shortcut.identity }).count == filter { $0.steps == nil && $0.sequence == nil }.count
    }
}

struct MotionProfile: Codable, Equatable {
    var scrollResponse: ScrollResponse? = nil
    var cursorResponse: CursorResponse? = nil
    var cursorSpeed: Double
    var cursorAcceleration: Double
    var scrollMultiplier: Double
    var invertScrollX: Bool
    var invertScrollY: Bool
    var kineticScroll: Bool
    var kineticDecay: Double
    // Optional preserves profiles saved before scroll acceleration existed.
    var scrollAcceleration: Double? = nil
    var resolvedScrollAcceleration: Double { min(ProfileMaximum.scrollAcceleration, max(1, scrollAcceleration ?? 1)) }
    // Optional preserves profiles saved before cursor deceleration existed.
    var cursorDeceleration: Double? = nil
    var fineCursorSpeed: Double? = nil
    var fineCursorAcceleration: Double? = nil
    var fineCursorFalloff: Double? = nil
    var cursorSpeedTransition: Double? = nil
    var resolvedCursorFalloff: Double { min(ProfileMaximum.cursorFalloff, max(0, cursorDeceleration ?? 0)) }
    var resolvedFineCursorSpeed: Double { min(ProfileMaximum.cursorSpeed, max(0, fineCursorSpeed ?? cursorSpeed)) }
    var resolvedFineCursorAcceleration: Double { min(ProfileMaximum.cursorAcceleration, max(1, fineCursorAcceleration ?? cursorAcceleration)) }
    var resolvedFineCursorFalloff: Double { min(ProfileMaximum.cursorFalloff, max(0, fineCursorFalloff ?? resolvedCursorFalloff)) }
    var resolvedCursorSpeedTransition: Double { min(ProfileMaximum.cursorSpeedTransition, max(1, cursorSpeedTransition ?? ProfileMaximum.cursorSpeedTransition * 0.5)) }
    var resolvedCursorResponse: CursorResponse { (cursorResponse ?? CursorResponse(legacy: self)).sanitized }

    mutating func copyCursorSettings(from source: MotionProfile) {
        cursorResponse = source.resolvedCursorResponse
        cursorSpeed = source.cursorSpeed
        cursorAcceleration = source.cursorAcceleration
        cursorDeceleration = source.cursorDeceleration
        fineCursorSpeed = source.fineCursorSpeed
        fineCursorAcceleration = source.fineCursorAcceleration
        fineCursorFalloff = source.fineCursorFalloff
        cursorSpeedTransition = source.cursorSpeedTransition
    }

    static let normal = MotionProfile(
        cursorSpeed: 0.28,
        cursorAcceleration: 1.37,
        scrollMultiplier: 1.0,
        invertScrollX: false,
        invertScrollY: false,
        kineticScroll: true,
        kineticDecay: 0.75
    )

    static let precision = MotionProfile(
        cursorSpeed: 0.25,
        cursorAcceleration: 1.0,
        scrollMultiplier: 0.1656,
        invertScrollX: false,
        invertScrollY: false,
        kineticScroll: true,
        kineticDecay: 0.9423446
    )
}

struct GestureSettings: Codable, Equatable {
    var tapToClick = true
    var tapMaxDuration = 0.25
    var tapMaxMovement = 30.0
    // Optional keeps existing configurations readable without rewriting them.
    var keepCursorStillForTaps: Bool? = nil
    var resolvedKeepCursorStillForTaps: Bool { keepCursorStillForTaps ?? true }
    var touchAndHoldDrag = true
    var dragRegrip = true
    var dragRegripWindow = 0.25
    var secondFingerGracePeriod = 0.05
    // Optional preserves settings saved before the recognition-delay control.
    var doubleTapInterval: Double?
    var tripleTapFirstInterval: Double?
    var tripleTapSecondInterval: Double?
    var resolvedTripleTapFirstInterval: Double { min(0.6, max(0.05, tripleTapFirstInterval ?? resolvedDoubleTapInterval)) }
    var resolvedTripleTapSecondInterval: Double { min(0.6, max(0.05, tripleTapSecondInterval ?? resolvedDoubleTapInterval)) }
    var resolvedDoubleTapInterval: Double { min(0.6, max(0.05, doubleTapInterval ?? 0.30)) }
}

enum SwipeDirection: String, Codable, CaseIterable {
    case left, right, up, down, topLeft, topRight, bottomLeft, bottomRight
    var title: String {
        switch self {
        case .left: return "Left"
        case .right: return "Right"
        case .up: return "Up"
        case .down: return "Down"
        case .topLeft: return "Top left"
        case .topRight: return "Top right"
        case .bottomLeft: return "Bottom left"
        case .bottomRight: return "Bottom right"
        }
    }
}

struct DoubleTapSwipeSettings: Codable, Equatable {
    var enabled = false
    var swipeWindow = 0.35
    var swipeDistance = 60.0
    // Used only by tap → swipe: the second contact must finish this quickly.
    var fastSwipeDuration: Double? = nil
    var resolvedFastDuration: Double { min(0.3, max(0.06, fastSwipeDuration ?? 0.18)) }
    static var singleTapDefaults: Self { Self(swipeWindow: 0.2) }
    var left: RecordedShortcut?
    var right: RecordedShortcut?
    var up: RecordedShortcut?
    var down: RecordedShortcut?
    var topLeft: RecordedShortcut?
    var topRight: RecordedShortcut?
    var bottomLeft: RecordedShortcut?
    var bottomRight: RecordedShortcut?
    var appExplorerDirections: [SwipeDirection]? = nil
    var isConfigured: Bool { enabled && SwipeDirection.allCases.contains { action(for: $0) != .none } }
    func action(for direction: SwipeDirection) -> TapAction {
        if appExplorerDirections?.contains(direction) == true { return .appExplorer }
        return self[direction] == nil ? .none : .shortcut
    }
    mutating func setAction(_ action: TapAction, for direction: SwipeDirection) {
        var directions = appExplorerDirections ?? []
        directions.removeAll { $0 == direction }
        if action == .appExplorer { directions.append(direction) }
        appExplorerDirections = directions.isEmpty ? nil : SwipeDirection.allCases.filter(directions.contains)
        if action != .shortcut { self[direction] = nil }
    }
    var resolvedWindow: Double { min(0.8, max(0.1, swipeWindow)) }
    var resolvedDistance: Double { min(240, max(20, swipeDistance)) }

    subscript(_ direction: SwipeDirection) -> RecordedShortcut? {
        get {
            switch direction {
            case .left: return left
            case .right: return right
            case .up: return up
            case .down: return down
            case .topLeft: return topLeft
            case .topRight: return topRight
            case .bottomLeft: return bottomLeft
            case .bottomRight: return bottomRight
            }
        }
        set {
            switch direction {
            case .left: left = newValue
            case .right: right = newValue
            case .up: up = newValue
            case .down: down = newValue
            case .topLeft: topLeft = newValue
            case .topRight: topRight = newValue
            case .bottomLeft: bottomLeft = newValue
            case .bottomRight: bottomRight = newValue
            }
        }
    }
}

struct ProfileGestures: Codable, Equatable {
    var twoFingerSwipe: DoubleTapSwipeSettings? = nil
    var gestures: GestureSettings
    var oneFingerTap: TapAction
    var twoFingerTap: TapAction
    var oneFingerShortcut: RecordedShortcut?
    var twoFingerShortcut: RecordedShortcut?
    // Optional so profiles saved before double-tap support keep working.
    var oneFingerDoubleTap: TapAction?
    var twoFingerDoubleTap: TapAction?
    var oneFingerDoubleShortcut: RecordedShortcut?
    var twoFingerDoubleShortcut: RecordedShortcut?
    var doubleTapSwipe: DoubleTapSwipeSettings? = nil
    var singleTapSwipe: DoubleTapSwipeSettings? = nil
    var oneFingerTapTwoFingerSwipe: DoubleTapSwipeSettings? = nil
    var twoFingerSingleTapSwipe: DoubleTapSwipeSettings? = nil
    var twoFingerDoubleTapSwipe: DoubleTapSwipeSettings? = nil
    var oneFingerTripleTap: TapAction? = nil
    var twoFingerTripleTap: TapAction? = nil
    var oneFingerTripleShortcut: RecordedShortcut? = nil
    var twoFingerTripleShortcut: RecordedShortcut? = nil

    /// Assigns one of the discrete tap gestures to an action reference. HUD
    /// layers and macros use the same portable RecordedShortcut representation.
    /// Swipe assignments keep their existing direction-specific editor.
    @discardableResult mutating func assignTapShortcut(_ shortcut: RecordedShortcut,
                                                        to trigger: AppGestureTrigger) -> Bool {
        gestures.tapToClick = true
        switch trigger {
        case .oneFingerTap:
            oneFingerTap = .shortcut; oneFingerShortcut = shortcut
        case .twoFingerTap:
            twoFingerTap = .shortcut; twoFingerShortcut = shortcut
        case .oneFingerDoubleTap:
            oneFingerDoubleTap = .shortcut; oneFingerDoubleShortcut = shortcut
        case .twoFingerDoubleTap:
            twoFingerDoubleTap = .shortcut; twoFingerDoubleShortcut = shortcut
        case .oneFingerTripleTap:
            oneFingerTripleTap = .shortcut; oneFingerTripleShortcut = shortcut
        case .twoFingerTripleTap:
            twoFingerTripleTap = .shortcut; twoFingerTripleShortcut = shortcut
        default:
            return false
        }
        return true
    }
    func tapTriggers(targetingHUDLayer id: UUID) -> [AppGestureTrigger] {
        let candidates: [(AppGestureTrigger, RecordedShortcut?)] = [
            (.oneFingerTap, oneFingerShortcut),
            (.oneFingerDoubleTap, oneFingerDoubleShortcut),
            (.oneFingerTripleTap, oneFingerTripleShortcut),
            (.twoFingerTap, twoFingerShortcut),
            (.twoFingerDoubleTap, twoFingerDoubleShortcut),
            (.twoFingerTripleTap, twoFingerTripleShortcut)
        ]
        return candidates.compactMap { trigger, shortcut in
            shortcut?.hudLayerID == id ? trigger : nil
        }
    }
}

struct AdditionalProfile: Codable, Identifiable {
    var id: UInt32
    var name: String
    var motion: MotionProfile
}

struct ProfileSliderBaseline: Codable {
    var cursorSpeed: Double
    var cursorAcceleration: Double
    var cursorFalloff: Double
    var scrollSpeed: Double
    var scrollAcceleration: Double
    var coastCoefficient: Double
    var tapImpactSpeed: Double
    var tapMovementRadius: Double
    var doubleTapDelay: Double
    var regripWindow: Double
}

struct StoredSettings: Codable {
    var actionBindings: [ActionBinding]? = nil
    func applyingActionBindings(to gestures: ProfileGestures) -> ProfileGestures {
        var result = gestures
        let assignedGestures = (actionBindings ?? []).filter { $0.isValid && $0.trigger.gesture != nil }
        // A profile-wide gesture enables recognition for its own input, not
        // every dormant action behind the layer's disabled-taps switch.
        if !gestures.gestures.tapToClick && !assignedGestures.isEmpty {
            for trigger in AppGestureTrigger.layerActionTriggers {
                _ = result.setLayerAction(.none, shortcut: nil, for: trigger)
            }
            result.gestures.tapToClick = false
        }
        for binding in assignedGestures {
            guard let trigger = binding.trigger.gesture else { continue }
            if [.twoFingerLeft, .twoFingerRight, .twoFingerUp, .twoFingerDown].contains(trigger) {
                var swipe = result.twoFingerSwipe ?? DoubleTapSwipeSettings()
                if let direction = trigger.direction {
                    swipe.setAction(.shortcut, for: direction)
                    swipe[direction] = .assigned(binding.action)
                    swipe.enabled = true
                    result.twoFingerSwipe = swipe
                }
            } else { _ = result.setLayerAction(.shortcut, shortcut: .assigned(binding.action), for: trigger) }
        }
        return result
    }
    var hotkeyDictionary: [NamedHotkey]? = nil
    var resolvedHotkeyDictionary: [NamedHotkey] { hotkeyDictionary ?? [] }
    var navigatorTapCalibration: TapCalibrationSettings? = nil
    var appleTapCalibration: TapCalibrationSettings? = nil
    // One Navigator response per top-level profile. Legacy layer motion stays
    // encoded for lossless old-config import, but is no longer selected by hotkeys.
    var pointerMotion: MotionProfile? = nil
    var pointerCoastBaseline: Double? = nil
    // One Navigator drag configuration per top-level profile. Legacy layer
    // values remain encoded and supply the migration fallback until edited.
    var navigatorDragging: DraggingSettings? = nil
    var navigatorRegripBaseline: Double? = nil
    var resolvedPointerMotion: MotionProfile {
        if let pointerMotion { return pointerMotion }
        let id = resolvedDefaultProfileID
        return id == 1 ? normal : id == 2 ? precision : additionalProfiles?.first { $0.id == id }?.motion ?? normal
    }
    var resolvedPointerCoastBaseline: Double {
        pointerCoastBaseline ?? sliderBaseline(for: resolvedDefaultProfileID).coastCoefficient
    }
    var resolvedNavigatorDragging: DraggingSettings {
        navigatorDragging ?? DraggingSettings(legacy: gestures(for: resolvedDefaultProfileID).gestures)
    }
    var resolvedNavigatorRegripBaseline: Double {
        navigatorRegripBaseline ?? sliderBaseline(for: resolvedDefaultProfileID).regripWindow
    }
    var devices: ProfileDevices? = nil
    var resolvedDevices: ProfileDevices { devices ?? ProfileDevices() }
    var appOverrides: [AppGestureOverride]? = nil
    var resolvedAppOverrides: [AppGestureOverride] { appOverrides ?? AppGestureOverride.defaults }
    var enabled = true
    var launchAtLogin = false
    var normal = MotionProfile.normal
    var precision = MotionProfile.precision
    var gestures = GestureSettings()
    var oneFingerTap: TapAction?
    var twoFingerTap: TapAction?
    var additionalProfiles: [AdditionalProfile]?
    // IDs 1 and 2 are retained in storage for backward-compatible motion data,
    // but can be removed from the user's action-layer list.
    var removedLayerIDs: Set<UInt32>?
    var profileNames: [UInt32: String]?
    var profileGestures: [UInt32: ProfileGestures]?
    var customTapProfiles: Set<UInt32>?
    var defaultProfileID: UInt32?
    var sliderBaselines: [UInt32: ProfileSliderBaseline]?
    var sliderBaselineRevision: Int?
    var appExplorer: AppExplorerSettings?
    var availableLayerIDs: [UInt32] {
        let removed = removedLayerIDs ?? []
        let ids = [UInt32(1), 2].filter { !removed.contains($0) } + (additionalProfiles ?? []).map(\.id)
        // Recover safely from corrupt local data. Imported configurations reject
        // removing every layer before they can reach this model.
        return ids.isEmpty ? [1] : ids
    }
    var resolvedDefaultProfileID: UInt32 {
        let id = defaultProfileID ?? availableLayerIDs[0]
        return availableLayerIDs.contains(id) ? id : availableLayerIDs[0]
    }

    mutating func makeDefault(_ id: UInt32) {
        guard availableLayerIDs.contains(id) else { return }
        guard id != resolvedDefaultProfileID else { return }
        // Changing the default action layer must not pick a different legacy
        // mouse response or drag behavior after importing an old config.
        pointerMotion = resolvedPointerMotion
        pointerCoastBaseline = resolvedPointerCoastBaseline
        navigatorDragging = resolvedNavigatorDragging
        navigatorRegripBaseline = resolvedNavigatorRegripBaseline
        let currentTaps = effectiveGestures(for: id)
        var stored = profileGestures ?? [:]
        stored[id] = currentTaps
        profileGestures = stored
        var custom = customTapProfiles ?? []
        custom.insert(resolvedDefaultProfileID)
        customTapProfiles = custom
        defaultProfileID = id
    }

    func gestures(for id: UInt32) -> ProfileGestures {
        profileGestures?[id] ?? ProfileGestures(gestures: gestures, oneFingerTap: oneFingerTap ?? .optionF19, twoFingerTap: twoFingerTap ?? .enter)
    }

    func effectiveGestures(for id: UInt32) -> ProfileGestures {
        var result = gestures(for: id)
        if id != resolvedDefaultProfileID && !(customTapProfiles ?? []).contains(id) {
            let primary = gestures(for: resolvedDefaultProfileID)
            result.oneFingerTap = primary.oneFingerTap
            result.twoFingerTap = primary.twoFingerTap
            result.oneFingerShortcut = primary.oneFingerShortcut
            result.twoFingerShortcut = primary.twoFingerShortcut
            result.oneFingerDoubleTap = primary.oneFingerDoubleTap
            result.twoFingerDoubleTap = primary.twoFingerDoubleTap
            result.oneFingerDoubleShortcut = primary.oneFingerDoubleShortcut
            result.twoFingerDoubleShortcut = primary.twoFingerDoubleShortcut
            result.doubleTapSwipe = primary.doubleTapSwipe
            result.singleTapSwipe = primary.singleTapSwipe
            result.oneFingerTapTwoFingerSwipe = primary.oneFingerTapTwoFingerSwipe
            result.twoFingerSingleTapSwipe = primary.twoFingerSingleTapSwipe
            result.twoFingerDoubleTapSwipe = primary.twoFingerDoubleTapSwipe
            result.twoFingerSwipe = primary.twoFingerSwipe
            result.oneFingerTripleTap = primary.oneFingerTripleTap
            result.twoFingerTripleTap = primary.twoFingerTripleTap
            result.oneFingerTripleShortcut = primary.oneFingerTripleShortcut
            result.twoFingerTripleShortcut = primary.twoFingerTripleShortcut
            result.gestures.tapToClick = primary.gestures.tapToClick
            result.gestures.tapMaxDuration = primary.gestures.tapMaxDuration
            result.gestures.tapMaxMovement = primary.gestures.tapMaxMovement
            result.gestures.keepCursorStillForTaps = primary.gestures.keepCursorStillForTaps
            result.gestures.doubleTapInterval = primary.gestures.doubleTapInterval
            result.gestures.tripleTapFirstInterval = primary.gestures.tripleTapFirstInterval
            result.gestures.tripleTapSecondInterval = primary.gestures.tripleTapSecondInterval
        }
        return result
    }

    func profileName(for id: UInt32, fallback: String) -> String {
        let name = profileNames?[id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? fallback : name
    }

    func sliderBaseline(for id: UInt32, preferStored: Bool = true) -> ProfileSliderBaseline {
        if preferStored, let saved = sliderBaselines?[id] { return saved }
        let motion = id == 1 ? normal : id == 2 ? precision : additionalProfiles?.first(where: { $0.id == id })?.motion ?? normal
        let profileGestures = effectiveGestures(for: id).gestures
        return ProfileSliderBaseline(cursorSpeed: motion.cursorSpeed, cursorAcceleration: motion.cursorAcceleration, cursorFalloff: motion.resolvedCursorFalloff, scrollSpeed: motion.scrollMultiplier, scrollAcceleration: motion.resolvedScrollAcceleration, coastCoefficient: motion.kineticDecay, tapImpactSpeed: profileGestures.tapMaxDuration, tapMovementRadius: profileGestures.tapMaxMovement, doubleTapDelay: profileGestures.resolvedDoubleTapInterval, regripWindow: profileGestures.dragRegripWindow)
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    // Neither cursor samples nor display refreshes invalidate the settings UI.
    let cursorTelemetry = CursorTelemetry()
    @Published var settings: StoredSettings { didSet { save() } }
    @Published private(set) var activeProfileID: UInt32 = 1
    @Published private(set) var configurationProfiles: [ConfigurationProfile] = []
    @Published private(set) var activeConfigurationID = "default"
    var captureShortcuts: (() -> ShortcutConfiguration)?
    var restoreShortcuts: ((ShortcutConfiguration) -> Void)?
    private var replacingProfile = false
    private static let libraryKey = "configurationProfiles.v1"

    private static let storageKey = "settings.v1"
    private let defaults: UserDefaults
    private let factorySettings: StoredSettings?

    init(defaults: UserDefaults = .standard, factorySettings: StoredSettings? = nil) {
        self.defaults = defaults
        self.factorySettings = factorySettings
        // Keep the legacy domain read-only so existing installations retain their tuning.
        if !defaults.bool(forKey: "migration.rotagivan.v1") {
            let legacy = defaults.persistentDomain(forName: "local.navigator.clone") ?? [:]
            for (key, value) in legacy where key == Self.storageKey || key.hasPrefix("shortcut.") {
                if defaults.object(forKey: key) == nil { defaults.set(value, forKey: key) }
            }
            defaults.set(true, forKey: "migration.rotagivan.v1")
        }
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode(StoredSettings.self, from: data) {
            settings = decoded
        } else {
            settings = StoredSettings()
            importZSASettingsIfPresent()
        }
        if settings.oneFingerTap == nil && settings.twoFingerTap == nil {
            settings.oneFingerTap = .optionF19
            settings.twoFingerTap = .enter
            settings.gestures.tapToClick = true
        }
        // Fine controls originally inherited their Fast counterpart so older
        // profiles would decode safely. Materialize that inherited value once:
        // changing Fast must never subsequently move a visible Fine control.
        if !defaults.bool(forKey: "migration.rotagivan.independentFineMotion.v1") {
            func materialized(_ motion: MotionProfile) -> MotionProfile {
                var result = motion
                if result.fineCursorSpeed == nil { result.fineCursorSpeed = result.cursorSpeed }
                if result.fineCursorAcceleration == nil { result.fineCursorAcceleration = result.cursorAcceleration }
                if result.fineCursorFalloff == nil { result.fineCursorFalloff = result.resolvedCursorFalloff }
                return result
            }
            var migrated = settings
            migrated.normal = materialized(migrated.normal)
            migrated.precision = materialized(migrated.precision)
            migrated.additionalProfiles = migrated.additionalProfiles?.map { profile in
                var result = profile
                result.motion = materialized(profile.motion)
                return result
            }
            settings = migrated
            defaults.set(true, forKey: "migration.rotagivan.independentFineMotion.v1")
        }
        // Preserve the visible 0–100 position when the physical velocity
        // range is widened from 800 to 4,000 contact-units/sec.
        if !defaults.bool(forKey: "migration.rotagivan.cursorTransitionRange.v1") {
            func widenedTransition(_ motion: MotionProfile) -> MotionProfile {
                var result = motion
                if let value = result.cursorSpeedTransition {
                    result.cursorSpeedTransition = min(ProfileMaximum.cursorSpeedTransition, max(0, value * 5))
                }
                return result
            }
            var migrated = settings
            migrated.normal = widenedTransition(migrated.normal)
            migrated.precision = widenedTransition(migrated.precision)
            migrated.additionalProfiles = migrated.additionalProfiles?.map { profile in
                var result = profile
                result.motion = widenedTransition(profile.motion)
                return result
            }
            settings = migrated
            defaults.set(true, forKey: "migration.rotagivan.cursorTransitionRange.v1")
        }
        // Revision 4 deliberately re-centres the user's existing live tuning
        // after profile baselines were introduced.
        if (settings.sliderBaselineRevision ?? 0) < 4 {
            let ids = settings.availableLayerIDs
            settings.sliderBaselines = Dictionary(uniqueKeysWithValues: ids.map { ($0, settings.sliderBaseline(for: $0, preferStored: false)) })
            settings.sliderBaselineRevision = 4
        }
        activeProfileID = settings.resolvedDefaultProfileID
        if let data = defaults.data(forKey: Self.libraryKey),
           let library = try? JSONDecoder().decode(ConfigurationLibrary.self, from: data),
           library.profiles.contains(where: { $0.id == library.activeID }) {
            configurationProfiles = library.profiles
            activeConfigurationID = library.activeID
        } else {
            configurationProfiles = [ConfigurationProfile(id: "default", name: "Default", settings: settings, shortcuts: ShortcutConfiguration())]
        }
    }

    var activeConfigurationName: String {
        configurationProfiles.first { $0.id == activeConfigurationID }?.name ?? "Default"
    }

    func profileSnapshot(shortcuts: ShortcutConfiguration? = nil) -> [ConfigurationProfile] {
        var result = configurationProfiles
        if let index = result.firstIndex(where: { $0.id == activeConfigurationID }) {
            result[index].settings = settings
            if let shortcuts = shortcuts ?? captureShortcuts?() { result[index].shortcuts = shortcuts }
        }
        return result
    }

    @discardableResult func renameConfiguration(_ name: String, for profileID: String? = nil) -> Bool {
        guard let index = configurationProfiles.firstIndex(where: { $0.id == (profileID ?? activeConfigurationID) }) else { return false }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 80 else { return false }
        configurationProfiles[index].name = trimmed
        save()
        return true
    }

    @discardableResult func addConfiguration() -> String {
        guard configurationProfiles.count < 20 else { return activeConfigurationID }
        configurationProfiles = profileSnapshot()
        let id = UUID().uuidString
        configurationProfiles.append(ConfigurationProfile(id: id, name: "Profile \(configurationProfiles.count + 1)",
            settings: settings, shortcuts: captureShortcuts?() ?? configurationProfiles.first { $0.id == activeConfigurationID }!.shortcuts))
        selectConfiguration(id)
        return id
    }

    func selectConfiguration(_ id: String) {
        guard id != activeConfigurationID, configurationProfiles.contains(where: { $0.id == id }) else { return }
        configurationProfiles = profileSnapshot()
        guard let target = configurationProfiles.first(where: { $0.id == id }) else { return }
        replacingProfile = true
        let enabled = settings.enabled, launch = settings.launchAtLogin
        activeConfigurationID = id
        var selected = target.settings
        selected.enabled = enabled
        selected.launchAtLogin = launch
        settings = selected
        activeProfileID = selected.resolvedDefaultProfileID
        restoreShortcuts?(target.shortcuts)
        cursorTelemetry.reset()
        replacingProfile = false
        save()
        NotificationCenter.default.post(name: .configurationProfileChanged, object: settings.resolvedDefaultProfileID)
    }

    func replaceLibrary(_ profiles: [ConfigurationProfile]?, activeID: String?, shortcuts: ShortcutConfiguration) {
        configurationProfiles = profiles ?? [ConfigurationProfile(id: "default", name: "Default", settings: settings, shortcuts: shortcuts)]
        activeConfigurationID = activeID ?? "default"
        if let index = configurationProfiles.firstIndex(where: { $0.id == activeConfigurationID }) {
            configurationProfiles[index].settings = settings
            configurationProfiles[index].shortcuts = shortcuts
        }
        persistLibrary()
        NotificationCenter.default.post(name: .configurationProfileChanged, object: settings.resolvedDefaultProfileID)
    }

    private func persistLibrary() {
        guard !configurationProfiles.isEmpty else { return }
        if let data = try? JSONEncoder().encode(ConfigurationLibrary(activeID: activeConfigurationID, profiles: profileSnapshot())) {
            defaults.set(data, forKey: Self.libraryKey)
        }
    }

    var activeProfile: MotionProfile {
        settings.resolvedPointerMotion
    }

    func updatePointerMotion(_ motion: MotionProfile) {
        var updated = settings
        updated.pointerCoastBaseline = updated.resolvedPointerCoastBaseline
        updated.pointerMotion = motion
        settings = updated
    }

    var navigatorDragging: DraggingSettings {
        settings.resolvedNavigatorDragging
    }

    func updateNavigatorDragging(_ value: DraggingSettings) {
        settings.navigatorDragging = value
    }

    @Published var foregroundBundleID: String?
    var activeGestures: ProfileGestures {
        activeGestures(for: .navigator)
    }

    func activeGestures(for device: GestureDevice) -> ProfileGestures {
        // Tap assignments belong to the single default HUD base layer. The
        // selected pointer-motion layer no longer changes tap behavior.
        let base = settings.applyingActionBindings(to: gestures(for: settings.resolvedDefaultProfileID, device: device))
        return settings.resolvedAppOverrides.first { $0.enabled && $0.bundleID == foregroundBundleID }?.applying(to: base) ?? base
    }

    func gestures(for id: UInt32, device: GestureDevice) -> ProfileGestures {
        var result = settings.effectiveGestures(for: id)
        if device == .apple, !settings.resolvedDevices.shareTapActions,
           let override = settings.devices?.appleLayerGestures?[id] { result = override }
        return tapCalibration(for: device).applying(to: result)
    }

    func tapCalibration(for device: GestureDevice) -> TapCalibrationSettings {
        (device == .apple ? settings.appleTapCalibration : settings.navigatorTapCalibration) ?? TapCalibrationSettings()
    }

    func updateTapCalibration(_ value: TapCalibrationSettings, for device: GestureDevice) {
        if device == .apple { settings.appleTapCalibration = value }
        else { settings.navigatorTapCalibration = value }
    }

    func updateAppleGestures(_ value: ProfileGestures?, for id: UInt32) {
        var devices = settings.resolvedDevices
        var overrides = devices.appleLayerGestures ?? [:]
        overrides[id] = value
        devices.appleLayerGestures = overrides.isEmpty ? nil : overrides
        settings.devices = devices
    }

    func updateGestures(_ value: ProfileGestures, for id: UInt32) {
        var profiles = settings.profileGestures ?? [:]
        profiles[id] = value
        settings.profileGestures = profiles
    }

    func recenterSliderBaselines(revision: Int) {
        guard (settings.sliderBaselineRevision ?? 0) < revision else { return }
        let ids = settings.availableLayerIDs
        var updated = settings
        updated.sliderBaselines = Dictionary(uniqueKeysWithValues: ids.map { ($0, updated.sliderBaseline(for: $0, preferStored: false)) })
        updated.sliderBaselineRevision = revision
        settings = updated
    }

    var profiles: [(id: UInt32, name: String)] {
        let defaults: [(id: UInt32, name: String)] = [(1, "Normal"), (2, "Precision")] + (settings.additionalProfiles ?? []).map { ($0.id, $0.name) }
        let available = Set(settings.availableLayerIDs)
        let named = defaults.filter { available.contains($0.id) }
            .map { (id: $0.id, name: settings.profileName(for: $0.id, fallback: $0.name)) }
        return named.filter { $0.id == defaultProfileID } + named.filter { $0.id != defaultProfileID }
    }

    var defaultProfileID: UInt32 { settings.resolvedDefaultProfileID }

    func makeDefault(_ id: UInt32) {
        var updated = settings
        updated.makeDefault(id)
        settings = updated
        activeProfileID = defaultProfileID
    }

    var activeProfileName: String { profiles.first { $0.id == activeProfileID }?.name ?? "Normal" }

    func setActiveProfile(_ id: UInt32) {
        activeProfileID = profiles.contains { $0.id == id } ? id : defaultProfileID
    }

    func motion(for id: UInt32) -> MotionProfile {
        if id == 1 { return settings.normal }
        if id == 2 { return settings.precision }
        return settings.additionalProfiles?.first { $0.id == id }?.motion ?? settings.normal
    }

    func updateMotion(_ motion: MotionProfile, for id: UInt32) {
        if id == 1 { settings.normal = motion }
        else if id == 2 { settings.precision = motion }
        else if let index = settings.additionalProfiles?.firstIndex(where: { $0.id == id }) {
            settings.additionalProfiles?[index].motion = motion
        }
    }

    @discardableResult
    func addProfile() -> UInt32 {
        let id = max(99, settings.additionalProfiles?.map(\.id).max() ?? 99) + 1
        let profile = AdditionalProfile(id: id, name: "Layer \(profiles.count + 1)", motion: motion(for: defaultProfileID))
        settings.additionalProfiles = (settings.additionalProfiles ?? []) + [profile]
        updateGestures(settings.gestures(for: defaultProfileID), for: id)
        var baselines = settings.sliderBaselines ?? [:]
        baselines[id] = settings.sliderBaseline(for: defaultProfileID)
        settings.sliderBaselines = baselines
        return id
    }

    func canRemoveProfile(_ id: UInt32) -> Bool {
        profiles.count > 1 && profiles.contains { $0.id == id }
    }

    /// Removes any visible action layer and every per-layer setting keyed by
    /// its ID. The legacy built-ins keep only their backward-compatible motion
    /// storage; custom layers are removed entirely.
    @discardableResult
    func removeProfile(_ id: UInt32) -> Bool {
        guard canRemoveProfile(id) else { return false }
        var updated = settings
        if id == updated.resolvedDefaultProfileID,
           let replacement = updated.availableLayerIDs.first(where: { $0 != id }) {
            updated.makeDefault(replacement)
        }
        if id == 1 || id == 2 {
            var removed = updated.removedLayerIDs ?? []
            removed.insert(id)
            updated.removedLayerIDs = removed
        } else {
            updated.additionalProfiles?.removeAll { $0.id == id }
        }
        updated.profileNames?.removeValue(forKey: id)
        updated.profileGestures?.removeValue(forKey: id)
        updated.customTapProfiles?.remove(id)
        updated.sliderBaselines?.removeValue(forKey: id)
        updated.devices?.appleLayerGestures?.removeValue(forKey: id)
        settings = updated
        if activeProfileID == id || !settings.availableLayerIDs.contains(activeProfileID) {
            activeProfileID = defaultProfileID
        }
        return true
    }

    func reset() {
        replaceSettings(factorySettings ?? StoredSettings())
    }

    func replaceSettings(_ value: StoredSettings) {
        settings = value
        activeProfileID = settings.resolvedDefaultProfileID
        cursorTelemetry.reset()
    }

    private func save() {
        guard !replacingProfile else { return }
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: Self.storageKey)
        }
        persistLibrary()
    }

    private func importZSASettingsIfPresent() {
        guard let domain = UserDefaults.standard.persistentDomain(forName: "io.zsa.navigator") else { return }
        settings.normal.cursorSpeed = (domain["cursor.speed"] as? NSNumber)?.doubleValue ?? settings.normal.cursorSpeed
        settings.normal.cursorAcceleration = (domain["cursor.acceleration"] as? NSNumber)?.doubleValue ?? settings.normal.cursorAcceleration
        settings.normal.scrollMultiplier = (domain["scroll.multiplier"] as? NSNumber)?.doubleValue ?? settings.normal.scrollMultiplier
        settings.normal.invertScrollX = (domain["scroll.invertX"] as? NSNumber)?.boolValue ?? settings.normal.invertScrollX
        settings.normal.invertScrollY = (domain["scroll.invertY"] as? NSNumber)?.boolValue ?? settings.normal.invertScrollY
        settings.normal.kineticScroll = (domain["scroll.kinetic.enabled"] as? NSNumber)?.boolValue ?? settings.normal.kineticScroll
        settings.normal.kineticDecay = (domain["scroll.kinetic.decay"] as? NSNumber)?.doubleValue ?? settings.normal.kineticDecay
        settings.gestures.tapToClick = (domain["gestures.tapToClickEnabled"] as? NSNumber)?.boolValue ?? settings.gestures.tapToClick
        settings.gestures.tapMaxDuration = (domain["gestures.tapMaxDuration"] as? NSNumber)?.doubleValue ?? settings.gestures.tapMaxDuration
        settings.gestures.tapMaxMovement = (domain["gestures.tapMaxMovement"] as? NSNumber)?.doubleValue ?? settings.gestures.tapMaxMovement
        settings.gestures.touchAndHoldDrag = (domain["gestures.touchAndHoldDrag"] as? NSNumber)?.boolValue ?? settings.gestures.touchAndHoldDrag
        settings.gestures.dragRegrip = (domain["gestures.dragRegrip"] as? NSNumber)?.boolValue ?? settings.gestures.dragRegrip
        settings.gestures.dragRegripWindow = (domain["gestures.dragRegripWindow"] as? NSNumber)?.doubleValue ?? settings.gestures.dragRegripWindow
        settings.gestures.secondFingerGracePeriod = (domain["gestures.secondFingerGracePeriod"] as? NSNumber)?.doubleValue ?? settings.gestures.secondFingerGracePeriod
        settings.precision = MotionProfile(
            cursorSpeed: max(0.05, settings.normal.cursorSpeed * 0.45),
            cursorAcceleration: max(1.0, settings.normal.cursorAcceleration * 0.8),
            scrollMultiplier: max(0.05, settings.normal.scrollMultiplier * 0.5),
            invertScrollX: settings.normal.invertScrollX,
            invertScrollY: settings.normal.invertScrollY,
            kineticScroll: settings.normal.kineticScroll,
            kineticDecay: settings.normal.kineticDecay
        )
    }
}
