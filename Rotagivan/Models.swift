import Foundation

extension Notification.Name {
    static let configurationProfileChanged = Notification.Name("Rotagivan.configurationProfileChanged")
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
    var holdToActivate = true
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

enum AppExplorerAction: String, Codable, CaseIterable {
    case windowManager, mediaControls, appWindows, maximize, toggleFullScreen, exitFullScreen, minimize, closeWindow
    var title: String {
        switch self {
        case .windowManager: return "Window Manager"
        case .mediaControls: return "Media Controls"
        case .appWindows: return "Show app windows"
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
        case .maximize: return "arrow.up.left.and.arrow.down.right"
        case .toggleFullScreen: return "arrow.up.left.and.down.right.and.arrow.up.right.and.down.left"
        case .exitFullScreen: return "arrow.down.right.and.arrow.up.left"
        case .minimize: return "minus.rectangle"
        case .closeWindow: return "xmark.rectangle"
        }
    }
    static let windowCommands: [Self] = [.maximize, .toggleFullScreen, .exitFullScreen, .minimize, .closeWindow]
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
        guard Self.legacy.contains(where: { $0.rawValue == rawValue }) ||
            [12, 16].flatMap({ Self.slots($0) }).contains(where: { $0.rawValue == rawValue }) else { return nil }
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
        let count = [4, 8, 12, 16].contains(count) ? count : 8
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
    var layout: ExplorerWindowLayout = .halves
    var layers: [ExplorerHoldLayer] = []
    var shortcuts: [ExplorerWindowShortcut] = []
}

enum ExplorerTheme: String, Codable, CaseIterable {
    case native, vector, ember, starburst
    var title: String {
        switch self { case .native: return "Classic"; case .vector: return "Vector HUD"; case .ember: return "Ember"; case .starburst: return "Starburst" }
    }
    var subtitle: String {
        switch self { case .native: return "Native · understated"; case .vector: return "Precision · electric"; case .ember: return "Warm · cinematic"; case .starburst: return "Radial · nested" }
    }
    var isHUD: Bool { self != .native }
}

enum ExplorerWindowLayout: String, Codable, CaseIterable {
    case halves, thirds, twoThirds, fourths
    var title: String { switch self { case .halves: return "Halves & quarters"; case .thirds: return "Thirds"; case .twoThirds: return "Two thirds"; case .fourths: return "Fourths (25%)" } }
    var fraction: Double { switch self { case .halves: return 0.5; case .thirds: return 1.0 / 3; case .twoThirds: return 2.0 / 3; case .fourths: return 0.25 } }
}

struct ExplorerHoldLayer: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var holdShortcut: RecordedShortcut?
    var favorites: [AppExplorerFavorite] = []
    var windowLayout: ExplorerWindowLayout = .halves
    var slotCount: Int? = nil
    var activation: ExplorerLayerActivation? = nil
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

struct AppExplorerFavorite: Codable, Equatable {
    var direction: ExplorerSlot
    var bundleID: String? = nil
    var name: String
    var url: String? = nil
    // A non-nil array is a named group, including an empty group.
    var children: [AppExplorerFavorite]? = nil
    // Optional so existing groups retain their manually assigned slots.
    var groupMode: AppExplorerMode? = nil
    var action: AppExplorerAction? = nil
    var shortcut: RecordedShortcut? = nil
    // Nil inherits the enclosing Explorer's keys; [] explicitly has no layers.
    // Stored on the tile so layers follow renames, moves, swaps and copies.
    var holdLayers: [ExplorerHoldLayer]? = nil
    var slotCount: Int? = nil
    var showsWindows: Bool? = nil
    var supportsHoldLayers: Bool { isGroup || isWindowManager }
    var isWindowManager: Bool { action == .windowManager }
    var isGroup: Bool { children != nil }
    var isRecentGroup: Bool { isGroup && groupMode == .recent }

    var resolvedWebURL: URL? { url.flatMap(Self.webURL) }
    var isValidDestination: Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 512 else { return false }
        guard holdLayers == nil || supportsHoldLayers else { return false }
        guard slotCount == nil || (isGroup && [4, 8, 12, 16].contains(slotCount!)) else { return false }
        guard showsWindows != true || (bundleID != nil && action == nil && !isGroup && url == nil && shortcut == nil) else { return false }
        if let shortcut {
            return shortcut.isValidExplorerShortcut && bundleID == nil && url == nil && children == nil && groupMode == nil && action == nil
        }
        if action != nil { return bundleID == nil && url == nil && children == nil && groupMode == nil }
        if isGroup { return bundleID == nil && url == nil }
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
    static let recentDirections: [ExplorerSlot] = [.left, .topLeft, .up, .topRight, .right, .bottomRight, .down, .bottomLeft]
    static let maximumGroupDepth = 4
    static let maximumFavorites = 256
    var defaultMode: AppExplorerMode = .favorites
    var favorites: [AppExplorerFavorite] = []
    var holdShortcut: RecordedShortcut?
    var holdLayers: [ExplorerHoldLayer]? = nil
    var theme: ExplorerTheme? = nil
    var animationsEnabled: Bool? = nil
    var centerCursorOnAppSwitch: Bool? = nil
    var slotCount: Int? = nil
    var windowManager: ExplorerWindowSettings? = nil
    var resolvedTheme: ExplorerTheme { theme ?? .vector }
    var resolvedAnimationsEnabled: Bool { animationsEnabled ?? true }
    var resolvedCenterCursorOnAppSwitch: Bool { centerCursorOnAppSwitch ?? false }
    func projected(layerID: UUID?) -> Self {
        guard let layer = holdLayers?.first(where: { $0.id == layerID }) else { return self }
        var result = self
        result.favorites = layer.favorites
        result.defaultMode = .favorites
        result.holdLayers = nil
        result.slotCount = layer.slotCount ?? slotCount
        return result
    }
    func mode(holdingShortcut: Bool) -> AppExplorerMode { holdingShortcut ? defaultMode.alternate : defaultMode }
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
        guard [4, 8, 12, 16].contains(count),
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
            next.favorites = layer.favorites
            next.defaultMode = .favorites
            next.slotCount = layer.slotCount ?? slotCount
        } else if var tile = favorite(at: path), tile.isGroup, let direction = path.last {
            tile.children = layer.favorites
            tile.groupMode = .favorites
            tile.slotCount = layer.slotCount ?? tile.slotCount
            next.setFavorite(tile, at: direction, in: Array(path.dropLast()))
        }
        return next
    }
    var hasValidFavorites: Bool {
        guard slotCount == nil || [4, 8, 12, 16].contains(slotCount!) else { return false }
        var remaining = Self.maximumFavorites
        var remainingLayers = 128
        func validLayers(_ layers: [ExplorerHoldLayer], depth: Int, groupDepth: Int, count: Int = 8) -> Bool {
            guard depth <= 12, layers.count <= 16, Set(layers.map(\.id)).count == layers.count else { return false }
            var keys = Set<String>()
            for layer in layers {
                remainingLayers -= 1
                guard remainingLayers >= 0, !layer.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      layer.name.count <= 128, layer.slotCount == nil || [4, 8, 12, 16].contains(layer.slotCount!) else { return false }
                if let key = layer.holdShortcut {
                    guard key.isValidExplorerShortcut, key.keyCode != 53,
                          !(key.keyCode == holdShortcut?.keyCode && key.modifiers == holdShortcut?.modifiers),
                          keys.insert("\(key.keyCode):\(key.modifiers)").inserted else { return false }
                }
                guard valid(layer.favorites, depth: groupDepth, nesting: depth + 1, count: layer.slotCount ?? count) else { return false }
            }
            return true
        }
        func valid(_ entries: [AppExplorerFavorite], depth: Int, nesting: Int = 0, count: Int = 8) -> Bool {
            guard [4, 8, 12, 16].contains(count), depth <= Self.maximumGroupDepth, nesting <= 12, entries.count <= count,
                  entries.allSatisfy({ ExplorerSlot.slots(count).contains($0.direction) }),
                  Set(entries.map(\.direction)).count == entries.count else { return false }
            for entry in entries {
                remaining -= 1
                guard remaining >= 0, entry.isValidDestination else { return false }
                if let children = entry.children, !valid(children, depth: depth + 1, nesting: nesting + 1, count: entry.slotCount ?? 8) { return false }
                if let layers = entry.holdLayers {
                    guard !entry.isWindowManager || layers.allSatisfy({ $0.favorites.isEmpty }),
                          validLayers(layers, depth: nesting + 1, groupDepth: entry.isGroup ? depth + 1 : depth, count: entry.slotCount ?? 8) else { return false }
                }
            }
            return true
        }
        if let windowManager {
            guard windowManager.layers.allSatisfy({ $0.favorites.isEmpty }),
                  validLayers(windowManager.layers, depth: 0, groupDepth: 0) else { return false }
            var keys = Set(windowManager.layers.compactMap { $0.holdShortcut }.map { "\($0.keyCode):\($0.modifiers)" })
            var commands = Set<AppExplorerAction>()
            for binding in windowManager.shortcuts {
                let key = binding.shortcut
                guard AppExplorerAction.windowCommands.contains(binding.command), commands.insert(binding.command).inserted,
                      key.isValidExplorerShortcut, key.keyCode != 53,
                      keys.insert("\(key.keyCode):\(key.modifiers)").inserted else { return false }
            }
        }
        return validLayers(holdLayers ?? [], depth: 0, groupDepth: 0, count: slotCount ?? 8) && valid(favorites, depth: 0, count: slotCount ?? 8)
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
}

struct ExplorerTileContainer: Identifiable {
    let id: [ExplorerTilePathStep]
    let title: String
    let count: Int
    let favorites: [AppExplorerFavorite]
}

extension AppExplorerSettings {
    /// All editable grids, including alternate layers belonging to nested groups.
    /// Recent-app grids and Window Manager layouts are generated, not destinations.
    func tileContainers(rootTitle: String = "Favorites") -> [ExplorerTileContainer] {
        guard hasValidFavorites else { return [] }
        var result: [ExplorerTileContainer] = []
        func visit(_ entries: [AppExplorerFavorite], layers: [ExplorerHoldLayer]?, count: Int,
                   path: [ExplorerTilePathStep], title: String, editable: Bool = true) {
            if editable {
                result.append(ExplorerTileContainer(id: path, title: title, count: count, favorites: entries))
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
            return "A group cannot be moved or copied into itself, or swapped with an enclosing group."
        }
        let displaced = container.favorites.first { $0.direction == target }
        guard !copy || displaced == nil else { return "Choose an empty slot for a copy. Move swaps occupied slots without deleting either tile." }
        var next = settings
        guard next.writeTile(moving, at: target, container: destination),
              copy || next.writeTile(displaced, at: slot, container: source), next.hasValidFavorites else {
            return "This would exceed the group-depth, tile, or custom-layer limits. Nothing was changed."
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
    mutating func press(key: UInt16, modifiers: UInt64, path: [ExplorerSlot], settings: AppExplorerSettings) -> Bool {
        if let existing = held.first(where: { $0.key == key }) {
            if existing.toggled { held.removeAll { $0.key == key } }
            return true
        }
        let current = resolved(settings)
        let scope = current.layerScope(at: path)
        guard let layer = current.layers(at: scope).first(where: {
            $0.holdShortcut?.keyCode == key && $0.holdShortcut?.modifiers == modifiers
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
        case .appExplorer: return "App Explorer"
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
    var isValidExplorerShortcut: Bool {
        let allowedModifiers: UInt64 = (1 << 17) | (1 << 18) | (1 << 19) | (1 << 20)
        return keyCode <= 127 && modifiers & ~allowedModifiers == 0 &&
            !keyLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && keyLabel.count <= 128 &&
            !keyLabel.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
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
    var twoFingerSingleTapSwipe: DoubleTapSwipeSettings? = nil
    var twoFingerDoubleTapSwipe: DoubleTapSwipeSettings? = nil
    var oneFingerTripleTap: TapAction? = nil
    var twoFingerTripleTap: TapAction? = nil
    var oneFingerTripleShortcut: RecordedShortcut? = nil
    var twoFingerTripleShortcut: RecordedShortcut? = nil
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
    // One Navigator response per top-level profile. Legacy layer motion stays
    // encoded for lossless old-config import, but is no longer selected by hotkeys.
    var pointerMotion: MotionProfile? = nil
    var pointerCoastBaseline: Double? = nil
    var resolvedPointerMotion: MotionProfile {
        if let pointerMotion { return pointerMotion }
        let id = resolvedDefaultProfileID
        return id == 1 ? normal : id == 2 ? precision : additionalProfiles?.first { $0.id == id }?.motion ?? normal
    }
    var resolvedPointerCoastBaseline: Double {
        pointerCoastBaseline ?? sliderBaseline(for: resolvedDefaultProfileID).coastCoefficient
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
    var profileNames: [UInt32: String]?
    var profileGestures: [UInt32: ProfileGestures]?
    var customTapProfiles: Set<UInt32>?
    var defaultProfileID: UInt32?
    var sliderBaselines: [UInt32: ProfileSliderBaseline]?
    var sliderBaselineRevision: Int?
    var appExplorer: AppExplorerSettings?
    var resolvedDefaultProfileID: UInt32 {
        let id = defaultProfileID ?? 1
        return id == 1 || id == 2 || (additionalProfiles ?? []).contains(where: { $0.id == id }) ? id : 1
    }

    mutating func makeDefault(_ id: UInt32) {
        guard id == 1 || id == 2 || (additionalProfiles ?? []).contains(where: { $0.id == id }) else { return }
        guard id != resolvedDefaultProfileID else { return }
        // Changing the default action layer must not pick a different legacy
        // mouse response, including immediately after importing an old config.
        pointerMotion = resolvedPointerMotion
        pointerCoastBaseline = resolvedPointerCoastBaseline
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
            let ids: [UInt32] = [1, 2] + (settings.additionalProfiles ?? []).map(\.id)
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

    func renameConfiguration(_ name: String) {
        guard let index = configurationProfiles.firstIndex(where: { $0.id == activeConfigurationID }) else { return }
        let trimmed = String(name.prefix(80))
        guard !trimmed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        configurationProfiles[index].name = trimmed
        save()
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

    @Published var foregroundBundleID: String?
    var activeGestures: ProfileGestures {
        activeGestures(for: .navigator)
    }

    func activeGestures(for device: GestureDevice) -> ProfileGestures {
        let base = gestures(for: activeProfileID, device: device)
        return settings.resolvedAppOverrides.first { $0.enabled && $0.bundleID == foregroundBundleID }?.applying(to: base) ?? base
    }

    func gestures(for id: UInt32, device: GestureDevice) -> ProfileGestures {
        if device == .apple, !settings.resolvedDevices.shareTapActions,
           let override = settings.devices?.appleLayerGestures?[id] { return override }
        return settings.effectiveGestures(for: id)
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
        let ids: [UInt32] = [1, 2] + (settings.additionalProfiles ?? []).map(\.id)
        var updated = settings
        updated.sliderBaselines = Dictionary(uniqueKeysWithValues: ids.map { ($0, updated.sliderBaseline(for: $0, preferStored: false)) })
        updated.sliderBaselineRevision = revision
        settings = updated
    }

    var profiles: [(id: UInt32, name: String)] {
        let defaults: [(id: UInt32, name: String)] = [(1, "Normal"), (2, "Precision")] + (settings.additionalProfiles ?? []).map { ($0.id, $0.name) }
        let named = defaults.map { (id: $0.id, name: settings.profileName(for: $0.id, fallback: $0.name)) }
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
