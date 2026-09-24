import SwiftUI

struct HUDSettingsView: View {
    @ObservedObject var store: SettingsStore
    @State private var selectedGroup: ExplorerReservedGroup?

    init(store: SettingsStore, initialGroup: ExplorerReservedGroup? = nil) {
        self.store = store
        _selectedGroup = State(initialValue: initialGroup)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            AppExplorerSettingsView(store: store)
            GroupBox("Built-in HUD layers") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Ready-made HUD layers, available from every tile’s HUD Layers menu.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        ForEach(ExplorerReservedGroup.allCases) { group in
                            Button { selectedGroup = group } label: {
                                Label(group.title, systemImage: group.symbol).frame(maxWidth: .infinity)
                            }.buttonStyle(.bordered).help(group.summary)
                        }
                    }
                }.padding(8)
            }
        }
        .sheet(item: $selectedGroup) { group in
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label(group.title, systemImage: group.symbol).font(.title2.weight(.semibold))
                    Spacer()
                    Button("Done") { selectedGroup = nil }.keyboardShortcut(.cancelAction)
                }
                Text("Built-in HUD layer · \(group.summary)").font(.callout).foregroundStyle(.secondary)
                ScrollView {
                    if group == .windowManager { WindowManagerSettingsView(store: store) }
                    else { ReservedGroupPreview(group: group) }
                }
            }.padding(24).frame(width: 660, height: 640)
        }
    }
}

struct ReservedGroupPreview: View {
    let group: ExplorerReservedGroup
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Assign this HUD layer to a tile using HUD Layers → \(group.title).")
            if group == .actions {
                Text("Each Actions layer starts with these shortcuts. Edit or rearrange its tiles independently. Commands go to the app you were using before opening the HUD; support varies by app.")
                    .font(.caption).foregroundStyle(.secondary)
                Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 12) {
                    ForEach(group.tile(at: .up).children ?? [], id: \.direction) { tile in
                        GridRow {
                            Text(tile.direction.title).foregroundStyle(.secondary)
                            Text(tile.name)
                            if let key = tile.shortcut {
                                Text("\(key.modifiers & (1 << 17) != 0 ? "⇧" : "")⌘\(key.keyLabel)")
                                    .monospaced().foregroundStyle(.secondary)
                            }
                        }
                    }
                }.padding(16).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            } else {
                Text("This HUD layer fills itself with running apps. The most recent app starts on the left, followed by the top-left, then clockwise. The current app is excluded. Tap the center to return to the previous layer.")
                Text("Its contents update on this Mac. Assign it from any tile, then edit that HUD layer to change its capacity or name.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct WindowManagerSettingsView: View {
    @ObservedObject var store: SettingsStore
    @State private var error: String?
    @State private var shortcutAction: TapAction = .shortcut
    @State private var editingBinding: ActionBinding?
    private var explorer: AppExplorerSettings { store.settings.appExplorer ?? AppExplorerSettings() }
    private var window: ExplorerWindowSettings {
        explorer.windowManager ?? ExplorerWindowSettings(layers: explorer.windowEditor().holdLayers ?? [])
    }
    private func save(_ updated: ExplorerWindowSettings) {
        var next = explorer; next.windowManager = updated
        guard next.hasValidFavorites else { error = "Use different keys for each window layer and command. Escape is reserved."; return }
        store.settings.appExplorer = next; error = nil
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Customize this HUD layer like the main HUD. Each tile can place the window, run a command, or open another HUD layer. Drag tiles to rearrange them; use the layer rail for alternate layouts.")
                .font(.callout).foregroundStyle(.secondary)
            AppExplorerSettingsView(store: store, configurationOverride: Binding(get: {
                explorer.windowEditor()
            }, set: { updated in
                var next = explorer
                guard next.saveWindowEditor(updated) else { error = "This HUD layer exceeds the nesting or tile limits."; return }
                store.settings.appExplorer = next; error = nil
            }), scopeTitle: "Window Manager", windowManagerOnly: true, windowApplet: true,
                windowOwnerPath: [])
            Divider()
            HStack {
                Text("Window Manager actions").font(.headline)
                Spacer()
                Button {
                    editingBinding = ActionBinding(trigger: BindingTrigger(),
                        action: .keystroke(RecordedShortcut(keyCode: 36, modifiers: 0, keyLabel: "Return")))
                } label: { Label("Add action", systemImage: "plus") }
            }
            ForEach(window.actionBindings ?? []) { binding in
                HStack {
                    Text(binding.trigger.title).fontWeight(.medium)
                    Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                    Text(binding.action.title)
                    Spacer()
                    Button("Edit") { editingBinding = binding }
                    Button {
                        var next = window
                        next.actionBindings?.removeAll { $0.id == binding.id }
                        save(next)
                    } label: { Image(systemName: "trash") }
                }.font(.system(size: 12))
            }
            Divider()
            Text("Window command hotkeys").font(.headline)
            Text("Fill desktop resizes within the current desktop. Full screen enters or exits a separate macOS Space. While full screen, only Exit full screen is offered.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(AppExplorerAction.windowCommands, id: \.self) { command in
                HStack {
                    TapActionEditor(title: command.title, action: $shortcutAction, shortcut: Binding(get: {
                        window.shortcuts.first { $0.command == command }?.shortcut
                    }, set: { shortcut in
                        var next = window; next.shortcuts.removeAll { $0.command == command }
                        if let shortcut { next.shortcuts.append(ExplorerWindowShortcut(command: command, shortcut: shortcut)) }
                        save(next)
                    }), keyboardOnly: true, physicalKeysOnly: true)
                    if window.shortcuts.contains(where: { $0.command == command }) {
                        Button("Clear") { var next = window; next.shortcuts.removeAll { $0.command == command }; save(next) }
                    }
                    Button("Add tap/swipe…") {
                        editingBinding = ActionBinding(trigger: BindingTrigger(), action: .command(command))
                    }
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .sheet(item: $editingBinding) { candidate in
            BindingEditor(binding: candidate, existing: window.actionBindings ?? [],
                reservedKeys: (window.favorites ?? []).compactMap(\.activationShortcut) +
                    window.layers.compactMap(\.holdShortcut) + window.shortcuts.map(\.shortcut),
                title: "Window Manager action", onSave: { updated in
                    var next = window
                    var bindings = next.actionBindings ?? []
                    if let index = bindings.firstIndex(where: { $0.id == updated.id }) { bindings[index] = updated }
                    else { bindings.append(updated) }
                    next.actionBindings = bindings
                    save(next)
                    editingBinding = nil
                }, onCancel: { editingBinding = nil })
        }
    }
}

private struct HUDLayerActivationSource: Hashable {
    let symbol: String
    let title: String
    let detail: String
}

struct AppExplorerSettingsView: View {
    @ObservedObject var store: SettingsStore
    @State private var editingURLPath: [ExplorerSlot]?
    @State private var editingShortcutPath: [ExplorerSlot]?
    @State private var selectedLayerID: UUID?
    @State private var editingLayer: ExplorerHoldLayer?
    @State private var editingDefaultLayer = false
    @State private var editingGroupHotkeys: [ExplorerSlot]?
    @State private var groupHotkeysSnapshot: AppExplorerFavorite?
    @State private var groupHotkeysOwnerID: UUID?
    @State private var creatingLayer = false
    @State private var removingLayer = false
    @State private var editingTileLayers: [ExplorerSlot]?
    @State private var tileLayerSnapshot: AppExplorerFavorite?
    @State private var tileLayerOwnerID: UUID?
    @State private var inheritTileLayers = false
    @State private var editingApplicationPath: [ExplorerSlot]?
    @State private var importingBookmarks = false
    @State private var groupPath: [ExplorerSlot]
    @State private var editingGroupPath: [ExplorerSlot]?
    @State private var removingGroupPath: [ExplorerSlot]?
    @State private var groupError: String?
    @State private var slotSpace = UUID()
    @State private var slotFrames: [ExplorerSlot: CGRect] = [:]
    @State private var slotDrag: ExplorerSlotDrag?
    @State private var dropTarget: ExplorerSlot?
    @State private var tileTransfer: ExplorerTileTransfer?
    @State private var previewSelection: ExplorerSlot = .up
    @State private var previewDrag: ExplorerSlotDrag?
    @State private var previewEditing: ExplorerSlot?
    @State private var editingTileBinding: ActionBinding?
    private let transferRoot: (() -> AppExplorerSettings)?
    private let transferSave: ((AppExplorerSettings) -> Bool)?
    private let transferPrefix: [ExplorerTilePathStep]
    private let windowOwnerPath: [ExplorerTilePathStep]?
    private var transferSettings: AppExplorerSettings { transferRoot?() ?? baseSettings }
    private var transferPath: [ExplorerTilePathStep] {
        transferPrefix + (selectedLayerID.map { [.layer($0)] } ?? []) + groupPath.map { .group($0) }
    }
    private let grid: [[ExplorerSlot?]] = [[.topLeft, .up, .topRight], [.left, nil, .right], [.bottomLeft, .down, .bottomRight]]
    private var baseSettings: AppExplorerSettings { configurationOverride?.wrappedValue ?? store.settings.appExplorer ?? AppExplorerSettings() }
    private let configurationOverride: Binding<AppExplorerSettings>?
    private let scopeTitle: String?
    private let windowManagerOnly: Bool
    private let windowApplet: Bool
    private var settings: AppExplorerSettings { baseSettings.projected(layerID: selectedLayerID) }
    private var favorites: [AppExplorerFavorite] { settings.favorites(at: groupPath) ?? [] }
    private var scopeBindings: [ActionBinding] {
        groupPath.isEmpty ? (settings.actionBindings ?? []) : (settings.favorite(at: groupPath)?.actionBindings ?? [])
    }
    private var legacyReservedKeys: [RecordedShortcut] {
        favorites.compactMap(\.activationShortcut) +
            settings.layers(at: settings.layerScope(at: groupPath)).compactMap(\.holdShortcut) +
            (windowOwnerPath == nil ? [] : (store.settings.appExplorer?.windowManager?.shortcuts.map(\.shortcut) ?? []))
    }
    private var isRecentGroup: Bool { settings.favorite(at: groupPath)?.isRecentGroup == true }
    private var availableBookmarkSlots: [ExplorerSlot] {
        let occupied = Set(favorites.map(\.direction))
        return ExplorerSlot.slots(settings.count(at: groupPath)).filter { !occupied.contains($0) }
    }
    private var existingBookmarkURLs: Set<String> {
        Set(favorites.compactMap(\.url))
    }
    private var themeBinding: Binding<ExplorerTheme> {
        Binding(get: { baseSettings.resolvedTheme }, set: { theme in
            var next = baseSettings; next.theme = theme; saveBase(next)
        })
    }
    private var animationBinding: Binding<Bool> {
        Binding(get: { baseSettings.resolvedAnimationsEnabled }, set: { enabled in
            var next = baseSettings; next.animationsEnabled = enabled; saveBase(next)
        })
    }
    private var centerCursorBinding: Binding<Bool> {
        Binding(get: { baseSettings.resolvedCenterCursorOnAppSwitch }, set: { enabled in
            var next = baseSettings; next.centerCursorOnAppSwitch = enabled; saveBase(next)
        })
    }
    private func activationSources(for layer: ExplorerHoldLayer?) -> [HUDLayerActivationSource] {
        let favorites = layer?.favorites ?? baseSettings.favorites
        let sources = favorites.compactMap { tile -> HUDLayerActivationSource? in
            guard let shortcut = tile.activationShortcut else { return nil }
            return HUDLayerActivationSource(symbol: "keyboard",
                title: shortcut.readableCombination, detail: tile.name)
        }
        let direct = ((layer == nil ? baseSettings.actionBindings : layer?.actionBindings) ?? []).compactMap { binding -> HUDLayerActivationSource? in
            guard binding.trigger.isValid else { return nil }
            return HUDLayerActivationSource(symbol: binding.trigger.keyboard == nil ? "hand.tap" : "keyboard",
                title: binding.trigger.title, detail: binding.action.title)
        }
        let allSources = direct + sources
        return allSources.isEmpty
            ? [HUDLayerActivationSource(symbol: "keyboard.badge.ellipsis", title: "No action hotkeys",
                detail: "Add a layer action")]
            : allSources
    }

    private func placeHUDLayer(_ id: UUID, at destination: HUDLayerPosition) {
        var next = baseSettings
        guard var layers = next.holdLayers,
              let source = layers.firstIndex(where: { $0.id == id }) else { return }
        let resolved = next.resolvedHUDPositions
        let previous = resolved[id]
        for index in layers.indices { layers[index].position = resolved[layers[index].id] }
        if let occupied = layers.firstIndex(where: { $0.position == destination && $0.id != id }) {
            layers[occupied].position = previous
        }
        layers[source].position = destination
        next.holdLayers = layers
        if saveBase(next) { selectedLayerID = id }
    }

    private func layerAt(_ position: HUDLayerPosition) -> ExplorerHoldLayer? {
        let resolved = baseSettings.resolvedHUDPositions
        return baseSettings.holdLayers?.first { resolved[$0.id] == position }
    }

    private func hudPositionCell(_ position: HUDLayerPosition) -> some View {
        Group {
            if let layer = layerAt(position) {
                hudLayerCard(layer, index: (baseSettings.holdLayers?.firstIndex(where: { $0.id == layer.id }) ?? 0) + 1)
                    .draggable(layer.id.uuidString)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: position.symbol).font(.title3)
                    Text("Drop a HUD here").font(.caption.weight(.medium))
                    Text(position.title).font(.caption2)
                }
                .foregroundStyle(.secondary)
                .frame(width: 220, height: 170)
                .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
            }
        }
        .dropDestination(for: String.self) { identifiers, _ in
            guard let value = identifiers.first, let id = UUID(uuidString: value),
                  baseSettings.holdLayers?.contains(where: { $0.id == id }) == true else { return false }
            placeHUDLayer(id, at: position)
            return true
        }
        .accessibilityIdentifier("hud-position-\(position.rawValue)")
    }

    private func hudLayerCard(_ layer: ExplorerHoldLayer?, index: Int) -> some View {
        let layerID = layer?.id
        let selected = selectedLayerID == layerID
        let sources = activationSources(for: layer)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                selectedLayerID = layerID
                groupPath = []
            } label: {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(String(format: "%02d", index + 1))
                            .font(.caption2.monospacedDigit().weight(.bold))
                            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                        Text(layer?.name ?? "Main HUD")
                            .font(.headline).lineLimit(1)
                        Spacer(minLength: 4)
                        if selected {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                        }
                    }
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(Array(sources.prefix(3)), id: \.self) { source in
                            HStack(alignment: .top, spacing: 7) {
                                Image(systemName: source.symbol)
                                    .frame(width: 14).foregroundStyle(Color.accentColor)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(source.title).font(.caption.weight(.semibold)).lineLimit(1)
                                    Text(source.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                        if sources.count > 3 {
                            Text("+\(sources.count - 3) more activation sources")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
                .padding(13).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if let layer {
                Divider()
                HStack(spacing: 12) {
                    Button("Edit hotkeys") {
                        if selected && !groupPath.isEmpty { openGroupHotkeys() }
                        else { creatingLayer = false; editingLayer = layer }
                    }
                    Spacer(minLength: 0)
                    Menu {
                        ForEach(HUDLayerPosition.allCases) { position in
                            Button(position.title, systemImage: position.symbol) {
                                placeHUDLayer(layer.id, at: position)
                            }
                        }
                    } label: {
                        Text(baseSettings.resolvedHUDPositions[layer.id]?.title ?? "Unplaced")
                    }
                    .help("Place \(layer.name) around the Main HUD")
                }
                .font(.caption).buttonStyle(.link).padding(.horizontal, 13).frame(height: 32)
            } else {
                Divider()
                HStack {
                    Label("Main HUD actions", systemImage: "safari")
                    Spacer(minLength: 0)
                    Button("Edit hotkeys") {
                        if !groupPath.isEmpty { openGroupHotkeys() }
                        else { editingDefaultLayer = true }
                    }
                        .buttonStyle(.link)
                }.font(.caption).padding(.horizontal, 13).frame(height: 32)
            }
        }
        .frame(width: 220)
        .background(selected ? Color.accentColor.opacity(0.09) : Color.primary.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(selected ? Color.accentColor.opacity(0.72) : Color.primary.opacity(0.1),
                              lineWidth: selected ? 1.5 : 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(layerID.map { "hud-layer-\($0.uuidString)" } ?? "hud-layer-default")
    }

    private var hudLayerRail: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("HUD layers").font(.headline)
                    Text("Select a layer to edit its tiles. Each card shows its hotkey → action assignments.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Drag a HUD to a position around Main, or choose a position on its card. Two-finger swipes move in that direction.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    importingBookmarks = true
                } label: {
                    Label("Import bookmarks", systemImage: "book.closed")
                }
                .disabled(isRecentGroup || availableBookmarkSlots.isEmpty)
                .help(availableBookmarkSlots.isEmpty ? "Remove a tile to make room for a bookmark." :
                    "Import Chrome or Safari bookmarks into open tiles in this HUD layer.")
                Button {
                    creatingLayer = true
                    editingLayer = .empty()
                } label: {
                    Label("Add HUD layer", systemImage: "plus")
                }
                .disabled((baseSettings.holdLayers ?? []).count >= 16 ||
                    (scopeTitle != nil && baseSettings.holdLayers == nil))
            }
            VStack(spacing: 10) {
                hudPositionCell(.top)
                HStack(alignment: .top, spacing: 10) {
                    hudPositionCell(.left)
                    hudLayerCard(nil, index: 0)
                    hudPositionCell(.right)
                }
                hudPositionCell(.bottom)
            }
            .frame(maxWidth: .infinity)
            let placed = baseSettings.resolvedHUDPositions
            let unplaced = (baseSettings.holdLayers ?? []).filter { placed[$0.id] == nil }
            if !unplaced.isEmpty {
                Text("Unplaced HUDs · assign a position to show one beside the active HUD")
                    .font(.caption).foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: true) {
                    HStack(spacing: 10) {
                        ForEach(unplaced) { layer in
                            hudLayerCard(layer, index: (baseSettings.holdLayers?.firstIndex(where: { $0.id == layer.id }) ?? 0) + 1)
                                .draggable(layer.id.uuidString)
                        }
                    }
                }
            }
        }
    }

    var compact = false
    var onGroupPathChange: (([ExplorerSlot]) -> Void)? = nil

    init(store: SettingsStore, groupPath: [ExplorerSlot] = [], compact: Bool = false, initialLayerID: UUID? = nil,
         configurationOverride: Binding<AppExplorerSettings>? = nil, scopeTitle: String? = nil, windowManagerOnly: Bool = false, windowApplet: Bool = false,
         transferRoot: (() -> AppExplorerSettings)? = nil, transferSave: ((AppExplorerSettings) -> Bool)? = nil,
         transferPrefix: [ExplorerTilePathStep] = [], windowOwnerPath: [ExplorerTilePathStep]? = nil,
         onGroupPathChange: (([ExplorerSlot]) -> Void)? = nil) {
        self.store = store
        _groupPath = State(initialValue: groupPath)
        _selectedLayerID = State(initialValue: initialLayerID)
        self.compact = compact
        self.configurationOverride = configurationOverride
        self.scopeTitle = scopeTitle
        self.windowManagerOnly = windowManagerOnly
        self.windowApplet = windowApplet
        self.transferRoot = transferRoot
        self.transferSave = transferSave
        self.transferPrefix = transferPrefix
        self.windowOwnerPath = windowOwnerPath
        self.onGroupPathChange = onGroupPathChange
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let scopeTitle {
                Label("Layers for \(scopeTitle)", systemImage: "square.3.layers.3d").font(.headline)
                Text(windowApplet ? "These layers belong to Window Manager. Hold a key temporarily, or tap a toggle key to switch tiles until you close the applet." : "These keys work only inside this tile. Hold temporarily or tap to toggle; leaving the tile returns to its default.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !windowApplet && !windowManagerOnly {
                Toggle("Use local HUD layers", isOn: Binding(get: { baseSettings.holdLayers != nil }, set: { custom in
                    if !custom && !(baseSettings.holdLayers ?? []).isEmpty { inheritTileLayers = true; return }
                    var next = baseSettings; next.holdLayers = custom ? [] : nil
                    saveBase(next); selectedLayerID = nil
                }))
                if baseSettings.holdLayers == nil {
                    Text("Inherit enclosing Explorer layers. Enable to use a separate set of keys here.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                }
            }
            if !compact && scopeTitle == nil {
                HStack {
                    Label("HUD layout", systemImage: "safari").font(.headline)
                    Spacer()
                    Picker("Theme", selection: themeBinding) {
                        ForEach(ExplorerTheme.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.frame(width: 230)
                    Menu {
                        Toggle("Animate HUD feedback", isOn: animationBinding)
                        Toggle("Put mouse in center of selected app", isOn: centerCursorBinding)
                    } label: { Label("Options", systemImage: "slider.horizontal.3") }.fixedSize()
                }
            }
            if compact {
                HStack {
                    if scopeTitle == nil {
                        Menu {
                            Picker("Theme", selection: themeBinding) {
                                ForEach(ExplorerTheme.allCases, id: \.self) { Text($0.title).tag($0) }
                            }
                            Toggle("Animate HUD feedback", isOn: animationBinding)
                            Toggle("Put mouse in center of selected app", isOn: centerCursorBinding)
                        } label: { Image(systemName: "paintpalette") }
                            .menuStyle(.borderlessButton).fixedSize().help("Explorer appearance")
                    }
                    Picker("HUD layer", selection: $selectedLayerID) {
                        Text("Default").tag(nil as UUID?)
                        ForEach(baseSettings.holdLayers ?? []) { layer in Text(layer.name).tag(Optional(layer.id)) }
                    }
                    Button("Add HUD layer") {
                        creatingLayer = true
                        editingLayer = .empty()
                    }.disabled((baseSettings.holdLayers ?? []).count >= 16 ||
                        (scopeTitle != nil && baseSettings.holdLayers == nil))
                    Button {
                        importingBookmarks = true
                    } label: {
                        Label("Import bookmarks", systemImage: "book.closed")
                    }
                    .disabled(isRecentGroup || availableBookmarkSlots.isEmpty)
                    .help(availableBookmarkSlots.isEmpty ? "Remove a tile to make room for a bookmark." :
                        "Import Chrome or Safari bookmarks into open tiles in this HUD layer.")
                    if !groupPath.isEmpty {
                        Button("Edit hotkeys…") { openGroupHotkeys() }
                    } else if let layer = baseSettings.holdLayers?.first(where: { $0.id == selectedLayerID }) {
                        Button("Edit hotkeys…") { creatingLayer = false; editingLayer = layer }
                        Button("Remove", role: .destructive) { removingLayer = true }
                    } else {
                        Button("Edit hotkeys…") { editingDefaultLayer = true }
                    }
                }.font(.subheadline)
            } else {
                hudLayerRail
            }
            if scopeTitle == nil && compact {
                Text("Assign keyboard shortcuts or trackpad gestures to this layer’s actions.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if windowManagerOnly {
                Text("Slot direction and window position are independent. Use ••• → Window management → Resize window to assign any position and size.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Picker(settings.favorite(at: groupPath)?.hasPrimaryDestination == true ? "Slots in this deep swipe" : "Slots in this HUD layer",
                selection: Binding(get: { settings.count(at: groupPath) }, set: { count in
                var next = settings
                guard next.resize(to: count, at: groupPath) else {
                    groupError = "Remove some tiles before choosing fewer slots. Your existing tiles have been kept."; return
                }
                _ = save(next)
            })) { ForEach(Array(2...16), id: \.self) { Text("\($0) slots").tag($0) } }
                .pickerStyle(.menu)
            HStack(spacing: 5) {
                Button(baseSettings.holdLayers?.first { $0.id == selectedLayerID }?.name ?? "Default") { groupPath = [] }
                    .buttonStyle(.link)
                ForEach(groupPath.indices, id: \.self) { index in
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    Button(settings.favorite(at: Array(groupPath.prefix(index + 1)))?.name ?? "HUD layer") {
                        groupPath = Array(groupPath.prefix(index + 1))
                    }.buttonStyle(.link).lineLimit(1)
                }
                Spacer(minLength: 4)
                if !groupPath.isEmpty {
                    Button("Edit hotkeys…") { openGroupHotkeys() }
                    Button("Rename…") { editingGroupPath = groupPath }
                }
            }.font(.subheadline.weight(.medium))
            if !groupPath.isEmpty, settings.favorite(at: groupPath)?.isPureGroup == true {
                Picker("HUD layer contents", selection: Binding(get: {
                    settings.favorite(at: groupPath)?.groupMode ?? .favorites
                }, set: { mode in
                    guard let direction = groupPath.last, var group = settings.favorite(at: groupPath) else { return }
                    group.groupMode = mode
                    edit { $0.setFavorite(group, at: direction, in: Array(groupPath.dropLast())) }
                })) {
                    Text("Assigned favorites").tag(AppExplorerMode.favorites)
                    Text("Recent apps").tag(AppExplorerMode.recent)
                }.pickerStyle(.segmented)
            }
            if !compact {
                ExplorerHUDSettingsPreview(settings: settings, theme: store.settings.appExplorer?.resolvedTheme ?? settings.resolvedTheme,
                    dictionary: store.settings.resolvedHotkeyDictionary, groupPath: groupPath,
                    layerName: baseSettings.holdLayers?.first { $0.id == selectedLayerID }?.name,
                    selection: $previewSelection, onBack: { if !groupPath.isEmpty { groupPath.removeLast() } },
                    onDrag: { source, target in
                        if previewDrag == nil { previewDrag = ExplorerSlotDrag(source: source, path: groupPath, settings: settings) }
                    }, onDrop: { _, target in
                        defer { previewDrag = nil }
                        guard let drag = previewDrag, let target else { return }
                        var next = settings
                        if drag.apply(to: target, in: groupPath, settings: &next), save(next) { previewSelection = target }
                    }, editingTile: $previewEditing, editor: { direction in tilePopover(direction) })
                    .padding(.top, -20)
                    .frame(maxWidth: .infinity)
            } else {
            VStack(spacing: 6) {
                if settings.count(at: groupPath) != 8 {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                        ForEach(ExplorerSlot.slots(settings.count(at: groupPath)), id: \.self) { direction in
                            if isRecentGroup { recentSlot(direction) } else { slot(direction) }
                        }
                    }
                } else {
                ForEach(0..<3) { row in
                    HStack(spacing: 6) {
                        ForEach(0..<3) { column in
                            if let direction = grid[row][column] {
                                if isRecentGroup { recentSlot(direction) }
                                else { slot(direction) }
                            }
                            else {
                                Button {
                                    if !groupPath.isEmpty { groupPath.removeLast() }
                                } label: {
                                    VStack(spacing: 5) {
                                        Image(systemName: groupPath.isEmpty ? "safari" : "arrow.uturn.backward")
                                            .font(.largeTitle).foregroundStyle(.teal)
                                        Text(groupPath.isEmpty ? (baseSettings.holdLayers?.first { $0.id == selectedLayerID }?.name ?? "Default") : "Back").font(.caption)
                                    }.frame(maxWidth: .infinity).frame(height: 88).contentShape(Rectangle())
                                }.buttonStyle(.plain).disabled(groupPath.isEmpty)
                            }
                        }
                    }
                }
                }
            }
            .coordinateSpace(name: slotSpace)
            .onPreferenceChange(ExplorerSlotFramesKey.self) { slotFrames = $0 }
            }
            Text(isRecentGroup
                ? "Filled automatically with your most recently used other running apps. Starts on the left, then goes clockwise. The current app is excluded. Any assigned favorites are kept if you switch back. Tap the center in the HUD to go back."
                : "Click a tile to edit it right there. Drag to rearrange, or choose Send to HUD layer to move it across layers. Preview clicks never launch apps or run actions.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .overlay(alignment: .bottomLeading) {
            if let groupError { Text(groupError).font(.caption).foregroundStyle(.red).padding(6).background(.regularMaterial) }
        }
        .sheet(isPresented: $importingBookmarks) {
            ExplorerBookmarkImporter(capacity: availableBookmarkSlots.count,
                existingURLs: existingBookmarkURLs, onImport: { bookmarks in
                    let slots = availableBookmarkSlots
                    guard !bookmarks.isEmpty, bookmarks.count <= slots.count else { return false }
                    var next = settings
                    for (bookmark, slot) in zip(bookmarks, slots) {
                        let favorite = AppExplorerFavorite(direction: slot, name: bookmark.title,
                            url: bookmark.url.absoluteString)
                        guard next.setFavorite(favorite, at: slot, in: groupPath) else { return false }
                    }
                    guard next.hasValidFavorites, save(next) else { return false }
                    importingBookmarks = false
                    groupError = nil
                    return true
                }, onCancel: { importingBookmarks = false })
        }
        .sheet(item: $tileTransfer) { transfer in
            ExplorerTileTransferEditor(transfer: transfer, onSave: { destination, slot, copy in
                var next = transferSettings
                if let error = transfer.apply(to: destination, slot: slot, copy: copy, settings: &next) { return error }
                guard commitTransfer(next) else { return "The configuration changed or could not be saved. Reopen Send to HUD layer." }
                tileTransfer = nil
                return nil
            }, onCancel: { tileTransfer = nil })
        }
        .confirmationDialog("Remove this tile’s custom layers and inherit enclosing Explorer keys?", isPresented: $inheritTileLayers, titleVisibility: .visible) {
            Button("Remove custom layers", role: .destructive) {
                var next = baseSettings; next.holdLayers = nil
                if saveBase(next) { selectedLayerID = nil }
            }
        }
        .sheet(isPresented: Binding(get: { editingTileLayers != nil }, set: { if !$0 { editingTileLayers = nil } })) {
            if let path = editingTileLayers, let tile = tileLayerSnapshot {
                VStack(alignment: .trailing) {
                    ScrollView {
                        AnyView(AppExplorerSettingsView(store: store, configurationOverride: tileLayerBinding(path),
                            scopeTitle: tile.name, windowManagerOnly: tile.isWindowManager,
                            transferRoot: tile.isWindowManager ? nil : { transferSettings }, transferSave: tile.isWindowManager ? nil : { next in
                                guard commitTransfer(next) else { return false }
                                // A transfer may move the group whose editor is open. Return to
                                // the parent instead of leaving a stale binding to its old slot.
                                editingTileLayers = nil
                                return true
                            }, transferPrefix: tile.isWindowManager ? [] : transferPrefix + (selectedLayerID.map { [.layer($0)] } ?? []) + path.map { .group($0) },
                            windowOwnerPath: tile.isWindowManager
                                ? (windowOwnerPath == nil ? transferPrefix + (selectedLayerID.map { [.layer($0)] } ?? []) + path.map { .group($0) } : nil)
                                : windowOwnerPath)).padding(24)
                    }
                    Button("Done") { editingTileLayers = nil }.keyboardShortcut(.cancelAction).padding()
                }.frame(width: 660, height: 620)
            }
        }
        .sheet(item: $editingLayer) { layer in
            HUDLayerHotkeyEditor(store: store, layer: layer, settings: baseSettings, onSave: { updated, tapDrafts in
                var next = baseSettings
                var layers = next.holdLayers ?? []
                if let index = layers.firstIndex(where: { $0.id == updated.id }) {
                    // Keep destinations that may have arrived via sync while the sheet was
                    // open. A hotkey is merged only when that exact tile stayed unchanged.
                    var merged = layers[index]
                    merged.name = updated.name
                    merged.favorites = mergingActionHotkeys(from: updated.favorites, into: merged.favorites)
                    merged.actionBindings = updated.actionBindings
                    layers[index] = merged
                } else {
                    guard creatingLayer else {
                        groupError = "This layer was removed while editing."; editingLayer = nil
                        return false
                    }
                    layers.append(updated)
                }
                next.holdLayers = layers
                guard next.hasValidFavorites else {
                    groupError = "Use unique hold keys and stay within the 16-layer / 256-slot limits."
                    return false
                }
                guard saveBase(next) else { return false }
                var stored = store.settings
                stored.updateHUDLayerTapAssignments(tapDrafts, for: updated)
                store.settings = stored
                selectedLayerID = updated.id; groupPath = []; editingLayer = nil; groupError = nil
                return true
            }, onCancel: { editingLayer = nil })
        }
        .sheet(isPresented: $editingDefaultLayer) {
            HUDLayerHotkeyEditor(store: store,
                layer: ExplorerHoldLayer(actionBindings: baseSettings.actionBindings,
                    name: "Default", holdShortcut: nil,
                    favorites: baseSettings.favorites, slotCount: baseSettings.slotCount),
                settings: baseSettings, onSave: { updated, _ in
                    var next = baseSettings
                    next.favorites = mergingActionHotkeys(from: updated.favorites, into: next.favorites)
                    next.actionBindings = updated.actionBindings
                    guard next.hasValidFavorites, saveBase(next) else { return false }
                    editingDefaultLayer = false
                    groupError = nil
                    return true
                }, onCancel: { editingDefaultLayer = false }, isDefaultLayer: true)
        }
        .sheet(isPresented: Binding(get: { editingGroupHotkeys != nil }, set: { if !$0 { editingGroupHotkeys = nil } })) {
            if let path = editingGroupHotkeys, let snapshot = groupHotkeysSnapshot {
                HUDLayerHotkeyEditor(store: store,
                    layer: ExplorerHoldLayer(actionBindings: snapshot.actionBindings,
                        name: snapshot.name, holdShortcut: nil,
                        favorites: snapshot.children ?? [], slotCount: snapshot.slotCount),
                    settings: settings, onSave: { updated, _ in
                        guard saveGroupHotkeyDraft(updated, at: path,
                                ownerID: groupHotkeysOwnerID, snapshot: snapshot) else { return false }
                        editingGroupHotkeys = nil; groupHotkeysSnapshot = nil; groupError = nil
                        return true
                    }, onCancel: { editingGroupHotkeys = nil },
                    isDefaultLayer: true, editingGroupPath: path,
                    layerTitle: snapshot.name + " hotkeys")
            }
        }
        .confirmationDialog("Remove this HUD layer and all its slots?", isPresented: $removingLayer, titleVisibility: .visible) {
            Button("Remove HUD layer", role: .destructive) {
                var next = baseSettings
                next.holdLayers?.removeAll { $0.id == selectedLayerID }
                saveBase(next)
                selectedLayerID = nil; groupPath = []
            }
        }
        .sheet(isPresented: Binding(get: { editingApplicationPath != nil }, set: { if !$0 { editingApplicationPath = nil } })) {
            if let path = editingApplicationPath, let direction = path.last {
                ExplorerDestinationPicker(direction: direction, onSave: { favorite, application in
                    var next = settings
                    guard next.setFavorite(preservingHotkey(favorite, at: path), at: direction, in: Array(path.dropLast())), next.hasValidFavorites else {
                        groupError = "The destination HUD layer changed. Reopen the picker and try again."
                        editingApplicationPath = nil
                        return
                    }
                    if let application { ExplorerApplicationCatalog.remember(application) }
                    guard save(next) else { return }
                    groupError = nil; editingApplicationPath = nil
                }, onCancel: { editingApplicationPath = nil })
            }
        }
        .sheet(isPresented: Binding(get: { editingShortcutPath != nil }, set: { if !$0 { editingShortcutPath = nil } })) {
            if let path = editingShortcutPath, let direction = path.last {
                let favorite = settings.favorite(at: path)
                ExplorerShortcutEditor(direction: direction,
                    name: favorite?.shortcut != nil ? (favorite?.name ?? "") : "",
                    shortcut: favorite?.shortcut, onSave: { favorite in
                        var next = settings
                        guard next.setFavorite(preservingHotkey(favorite, at: path), at: direction, in: Array(path.dropLast())), next.hasValidFavorites else {
                            groupError = "The destination HUD layer changed. Reopen the shortcut editor and try again."
                            editingShortcutPath = nil
                            return
                        }
                        guard save(next) else { return }
                        groupError = nil; editingShortcutPath = nil
                    }, onCancel: { editingShortcutPath = nil })
            }
        }
        .sheet(item: $editingTileBinding) { candidate in
            BindingEditor(binding: candidate, existing: scopeBindings,
                reservedKeys: legacyReservedKeys, title: "HUD action",
                onSave: { updated in
                    saveScopeBinding(updated)
                    editingTileBinding = nil
                }, onCancel: { editingTileBinding = nil })
        }
        .sheet(isPresented: Binding(get: { editingURLPath != nil }, set: { if !$0 { editingURLPath = nil } })) {
            if let path = editingURLPath, let direction = path.last {
                let favorite = settings.favorite(at: path)
                ExplorerURLFavoriteEditor(direction: direction,
                    name: favorite?.url != nil ? (favorite?.name ?? "") : "",
                    address: favorite?.url ?? "", iconSymbol: favorite?.url != nil ? favorite?.iconSymbol : nil,
                    onSave: { favorite in
                        edit { $0.setFavorite(preservingHotkey(favorite, at: path), at: direction, in: Array(path.dropLast())) }
                        editingURLPath = nil
                    }, onCancel: { editingURLPath = nil })
            }
        }
        .sheet(isPresented: Binding(get: { editingGroupPath != nil }, set: { if !$0 { editingGroupPath = nil } })) {
            if let path = editingGroupPath {
                let favorite = settings.favorite(at: path)
                ExplorerGroupNameEditor(name: favorite?.isGroup == true ? favorite!.name : "",
                    isNew: favorite?.isGroup != true, onSave: { name in
                        guard let direction = path.last else { return }
                        var next = settings
                        var group = next.favorite(at: path).flatMap { $0.isGroup ? $0 : nil }
                            ?? AppExplorerFavorite(direction: direction, name: name, children: [])
                        group.name = name
                        guard next.setFavorite(group, at: direction, in: Array(path.dropLast())), next.hasValidFavorites else {
                            groupError = "HUD layers support four nested levels and 256 total tiles. The parent layer must still exist."
                            editingGroupPath = nil
                            return
                        }
                        guard save(next) else { return }
                        groupError = nil; editingGroupPath = nil
                        if !group.isWindowManager { groupPath = path }
                    }, onCancel: { editingGroupPath = nil })
            }
        }
        .confirmationDialog("Remove this HUD layer and all its tiles?", isPresented: Binding(get: { removingGroupPath != nil }, set: { if !$0 { removingGroupPath = nil } }), titleVisibility: .visible) {
            Button("Remove HUD layer", role: .destructive) {
                if let path = removingGroupPath, let direction = path.last {
                    edit { $0.setFavorite(nil, at: direction, in: Array(path.dropLast())) }
                }
                removingGroupPath = nil
            }
            Button("Cancel", role: .cancel) { removingGroupPath = nil }
        }
        .onChange(of: settings) { _, _ in
            while !groupPath.isEmpty && settings.favorites(at: groupPath) == nil { groupPath.removeLast() }
        }
        .onChange(of: selectedLayerID) { _, _ in groupPath = []; groupError = nil; slotDrag = nil; dropTarget = nil; previewDrag = nil; previewEditing = nil }
        .onChange(of: editingShortcutPath) { _, _ in previewEditing = nil }
        .onChange(of: editingURLPath) { _, _ in previewEditing = nil }
        .onChange(of: editingGroupPath) { _, _ in previewEditing = nil }
        .onChange(of: editingApplicationPath) { _, _ in previewEditing = nil }
        .onChange(of: editingTileLayers) { _, _ in previewEditing = nil }
        .onChange(of: tileTransfer != nil) { _, _ in previewEditing = nil }
        .onChange(of: baseSettings.holdLayers) { _, layers in
            if let selectedLayerID, layers?.contains(where: { $0.id == selectedLayerID }) != true { self.selectedLayerID = nil }
        }
        .onChange(of: groupPath) { _, path in previewDrag = nil; previewEditing = nil; onGroupPathChange?(path) }
        .onChange(of: settings.count(at: groupPath)) { _, count in
            if !ExplorerSlot.slots(count).contains(previewSelection) { previewSelection = .up }
            previewDrag = nil
        }
        .onDisappear { slotDrag = nil; dropTarget = nil }
    }

    private func tilePopover(_ direction: ExplorerSlot) -> AnyView {
        let favorite = favorites.first { $0.direction == direction }
        return AnyView(VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Edit \(direction.title) tile").font(.headline)
                    Text(favorite == nil ? "Choose what this tile does" : "Replace or manage its current action")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { previewEditing = nil } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .help("Close tile editor")
            }
            .padding(16)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                if let favorite {
                    HStack(spacing: 10) {
                        tileAssignmentIcon(favorite)
                            .frame(width: 26, height: 26)
                            .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(favorite.name).fontWeight(.medium).lineLimit(1)
                            Text("Current assignment").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(10)
                    .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 9))

                    VStack(alignment: .leading, spacing: 7) {
                        Text("HOTKEY FOR THIS ACTION")
                            .font(.caption2.weight(.semibold)).tracking(0.8).foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            ShortcutRecorder(title: favorite.activationShortcut?.readableCombination ?? "Assign hotkey…") { shortcut in
                                var updated = favorite
                                updated.activationShortcut = shortcut
                                edit { $0.setFavorite(updated, at: direction, in: groupPath) }
                            }
                            .frame(maxWidth: .infinity, minHeight: 28)
                            if favorite.activationShortcut != nil {
                                Button("Clear") {
                                    var updated = favorite
                                    updated.activationShortcut = nil
                                    edit { $0.setFavorite(updated, at: direction, in: groupPath) }
                                }
                            }
                        }
                        Text("Works while this HUD layer is open. Escape and bare E/S stay reserved for HUD controls.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button("Assign tap or swipe to this action…") {
                            guard let assigned = tileBindingAction(favorite, at: direction) else { return }
                            editingTileBinding = ActionBinding(trigger: BindingTrigger(), action: assigned)
                        }
                        .disabled(tileBindingAction(favorite, at: direction) == nil)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("ACTION")
                        .font(.caption2.weight(.semibold)).tracking(0.8).foregroundStyle(.secondary)
                    BindingActionPicker(action: Binding(get: {
                        favorite.flatMap(BindingAction.from(favorite:)) ?? .tap(.none)
                    }, set: { selected in
                        guard let replacement = selected.favorite(at: direction) else { return }
                        edit { $0.setFavorite(preservingHotkey(replacement,
                            at: groupPath + [direction]), at: direction, in: groupPath) }
                    }))
                }

                Text("ACTIONS")
                    .font(.caption2.weight(.semibold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    Menu {
                        Button("Choose app…", systemImage: "app") {
                            editingApplicationPath = groupPath + [direction]
                        }
                        Button(favorite?.url != nil ? "Edit URL…" : "Open URL…", systemImage: "globe") {
                            editingURLPath = groupPath + [direction]
                        }
                        if let favorite, favorite.bundleID != nil {
                            Divider()
                            Toggle("Show this app’s windows", isOn: Binding(get: {
                                favorite.showsWindows == true
                            }, set: { enabled in
                                var updated = favorite
                                updated.showsWindows = enabled
                                edit { $0.setFavorite(updated, at: direction, in: groupPath) }
                            }))
                        }
                    } label: {
                        ExplorerTileActionLabel(title: "Apps & websites", detail: "Launch an app or URL", systemImage: "app.badge", showsMenu: true)
                    }
                    .menuStyle(.borderlessButton)
                    .frame(maxWidth: .infinity)

                    Button {
                        editingShortcutPath = groupPath + [direction]
                    } label: {
                        ExplorerTileActionLabel(title: "Keyboard & macros", detail: "Keys, shortcuts, sequences", systemImage: "keyboard")
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                }

                HStack(spacing: 10) {
                    Menu {
                        ForEach(ExplorerReservedGroup.allCases) { group in
                            Button(group.title, systemImage: group.symbol) {
                                let tile = preservingHotkey(group.tile(at: direction, insideWindowManager: windowManagerOnly),
                                    at: groupPath + [direction])
                                edit { $0.setFavorite(tile, at: direction, in: groupPath) }
                                previewEditing = nil
                            }
                            .disabled(groupPath.count >= AppExplorerSettings.maximumGroupDepth &&
                                (group != .windowManager || windowManagerOnly))
                        }
                        Divider()
                        Button("Create HUD layer…", systemImage: "square.3.layers.3d") {
                            editingGroupPath = groupPath + [direction]
                        }
                        .disabled(groupPath.count >= AppExplorerSettings.maximumGroupDepth)
                    } label: {
                        ExplorerTileActionLabel(title: "HUD layers", detail: "Open or create another layer", systemImage: "square.3.layers.3d", showsMenu: true)
                    }
                    .menuStyle(.borderlessButton)
                    .frame(maxWidth: .infinity)

                    Menu {
                        Menu("Resize window") {
                            windowActionButton(.maximize, at: direction, closeEditor: true)
                            Divider()
                            ForEach(ExplorerWindowLayout.allCases, id: \.self) { layout in
                                Menu(layout.title) {
                                    ForEach(SwipeDirection.allCases, id: \.self) { placementDirection in
                                        let placement = ExplorerWindowPlacement(direction: placementDirection, layout: layout)
                                        Button(placement.title) {
                                            edit {
                                                $0.setFavorite(preservingHotkey(AppExplorerFavorite(direction: direction, name: placement.title,
                                                    windowPlacement: placement), at: groupPath + [direction]), at: direction, in: groupPath)
                                            }
                                            previewEditing = nil
                                        }
                                    }
                                }
                            }
                        }
                        Menu("Full screen") {
                            windowActionButton(.toggleFullScreen, at: direction, closeEditor: true)
                            windowActionButton(.exitFullScreen, at: direction, closeEditor: true)
                        }
                        Divider()
                        windowActionButton(.minimize, at: direction, closeEditor: true)
                        windowActionButton(.closeWindow, at: direction, closeEditor: true)
                    } label: {
                        ExplorerTileActionLabel(title: "Window management", detail: "Move, resize, full screen", systemImage: "macwindow", showsMenu: true)
                    }
                    .menuStyle(.borderlessButton)
                    .frame(maxWidth: .infinity)
                }

                HStack(spacing: 10) {
                    Menu {
                        ForEach(AppExplorerAction.macOSCommands, id: \.self) { action in
                            windowActionButton(action, at: direction, closeEditor: true)
                        }
                    } label: {
                        ExplorerTileActionLabel(title: "Mac commands", detail: "Mission Control, desktops, app windows",
                            systemImage: "macbook", showsMenu: true)
                    }
                    .menuStyle(.borderlessButton)
                    .frame(maxWidth: .infinity)

                    Button {
                        edit {
                            $0.setFavorite(preservingHotkey(AppExplorerFavorite(direction: direction, name: "Media Controls",
                                action: .mediaControls), at: groupPath + [direction]), at: direction, in: groupPath)
                        }
                        previewEditing = nil
                    } label: {
                        ExplorerTileActionLabel(title: "Media controls", detail: "Playback and volume controls",
                            systemImage: "speaker.wave.2.fill", compact: true)
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                }

                if favorite != nil {
                    Divider().padding(.top, 2)
                    VStack(alignment: .leading, spacing: 8) {
                        if let favorite, favorite.isPureGroup {
                            HStack(spacing: 12) {
                                Button(favorite.isWindowManager ? "Edit Window Manager…" : "Edit HUD layer…") {
                                    if favorite.isWindowManager {
                                        tileLayerSnapshot = favorite
                                        tileLayerOwnerID = selectedLayerID
                                        editingTileLayers = groupPath + [direction]
                                    } else {
                                        groupPath.append(direction)
                                        previewEditing = nil
                                    }
                                }
                                Button("Rename…") { editingGroupPath = groupPath + [direction] }
                            }
                        } else if let favorite, favorite.supportsHoldLayers && !favorite.hasDeepChoices {
                            Button("Edit HUD layers…") {
                                tileLayerSnapshot = favorite
                                tileLayerOwnerID = selectedLayerID
                                editingTileLayers = groupPath + [direction]
                            }
                        }
                        if let favorite, favorite.hasPrimaryDestination {
                            Button(favorite.hasDeepChoices ? "Edit deep swipe options…" : "Add deep swipe options…") {
                                var updated = favorite
                                if updated.children == nil { updated.children = [] }
                                if updated.slotCount == nil { updated.slotCount = 4 }
                                edit { $0.setFavorite(updated, at: direction, in: groupPath) }
                                groupPath.append(direction)
                                previewEditing = nil
                            }
                        }
                        HStack(spacing: 14) {
                            Button("Send to HUD layer…") {
                                tileTransfer = ExplorerTileTransfer(snapshot: transferSettings, source: transferPath, slot: direction)
                            }
                            Menu("Move within this layer") {
                                ForEach(ExplorerSlot.slots(settings.count(at: groupPath)).filter { $0 != direction }, id: \.self) { target in
                                    Button(target.title) {
                                        edit { $0.swapFavorites(from: direction, to: target, in: groupPath) }
                                        previewEditing = nil
                                    }
                                }
                            }
                            Spacer()
                            Button("Remove tile", role: .destructive) {
                                edit { $0.setFavorite(nil, at: direction, in: groupPath) }
                                previewEditing = nil
                            }
                        }
                    }
                    .font(.caption)
                    .controlSize(.small)
                }
            }
            .padding(16)
        }
        .frame(width: 560))
    }

    @ViewBuilder private func tileAssignmentIcon(_ favorite: AppExplorerFavorite) -> some View {
        if let icon = Self.applicationIcon(for: favorite) {
            Image(nsImage: icon).resizable().renderingMode(.original).scaledToFit().padding(5)
        } else if let action = favorite.action {
            Image(systemName: action.symbol).foregroundStyle(.teal)
        } else if favorite.shortcut != nil {
            Image(systemName: "keyboard").foregroundStyle(.teal)
        } else if favorite.windowPlacement != nil {
            Image(systemName: "macwindow").foregroundStyle(.teal)
        } else if favorite.isWindowManager {
            Image(systemName: "rectangle.split.2x2").foregroundStyle(.teal)
        } else if favorite.url != nil {
            WebsiteFavicon(url: favorite.resolvedWebURL, size: 18, symbolName: favorite.iconSymbol)
        } else {
            Image(systemName: favorite.isRecentGroup ? "clock.arrow.circlepath" :
                (favorite.isGroup ? "folder.fill" : (favorite.url != nil ? "globe" : "app")))
                .foregroundStyle(.teal)
        }
    }

    private func slot(_ direction: ExplorerSlot, editingPreview: Bool = false) -> some View {
        let favorite = favorites.first { $0.direction == direction }
        let icon = Self.applicationIcon(for: favorite)
        return VStack(spacing: 5) {
            HStack {
                Text(direction.title).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Menu {
                    if let favorite, favorite.supportsHoldLayers && !favorite.hasDeepChoices {
                        Button(favorite.isWindowManager ? "Edit Window Manager layer…" : "Edit HUD layers…") {
                            tileLayerSnapshot = favorite
                            tileLayerOwnerID = selectedLayerID
                            editingTileLayers = groupPath + [direction]
                        }
                        Divider()
                    }
                    if favorite?.isPureGroup == true {
                        if favorite?.isWindowManager != true { Button("Edit HUD layer…") { groupPath.append(direction) } }
                        Button("Rename HUD layer…") { editingGroupPath = groupPath + [direction] }
                    } else {
                        assignmentMenu(direction, favorite: favorite)
                        if let favorite, favorite.hasPrimaryDestination {
                            Button(favorite.hasDeepChoices ? "Edit deep swipe options…" : "Add deep swipe options…") {
                                var updated = favorite
                                if updated.children == nil { updated.children = []; updated.slotCount = 4 }
                                edit { $0.setFavorite(updated, at: direction, in: groupPath) }
                                groupPath.append(direction)
                            }
                        }
                    }
                    if favorite != nil {
                        Divider()
                        Button("Send to HUD layer…") {
                            tileTransfer = ExplorerTileTransfer(snapshot: transferSettings, source: transferPath, slot: direction)
                        }
                        Menu("Move within this layer") {
                            ForEach(ExplorerSlot.slots(settings.count(at: groupPath)).filter { $0 != direction }, id: \.self) { target in
                                Button(target.title) { edit { $0.swapFavorites(from: direction, to: target, in: groupPath) } }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 16, height: 16)
                }.menuStyle(.borderlessButton).fixedSize()
                    .help("Edit \(direction.title) slot")
                    .accessibilityLabel("Edit \(direction.title) slot")
            }.padding(.horizontal, 10)
            if let favorite {
                Label {
                    Text(favorite.shortcut.flatMap { key in
                        store.settings.resolvedHotkeyDictionary.label(for: key).map { _ in store.settings.resolvedHotkeyDictionary.title(for: key) }
                    } ?? favorite.name).lineLimit(2)
                } icon: {
                    if let icon {
                        Image(nsImage: icon).resizable().renderingMode(.original)
                            .scaledToFit().frame(width: 16, height: 16)
                    } else if let action = favorite.action {
                        Image(systemName: action.symbol).foregroundStyle(.teal).frame(width: 16, height: 16)
                    } else if favorite.shortcut != nil {
                        Image(systemName: "keyboard").foregroundStyle(.teal).frame(width: 16, height: 16)
                    } else if let placement = favorite.windowPlacement {
                        WindowTileIcon(direction: placement.direction, layout: placement.layout).frame(width: 24, height: 24)
                    } else if favorite.isWindowManager {
                        Image(systemName: "rectangle.split.2x2").foregroundStyle(.teal).frame(width: 16, height: 16)
                    } else if favorite.url != nil {
                        WebsiteFavicon(url: favorite.resolvedWebURL, size: 16, symbolName: favorite.iconSymbol)
                    } else {
                        Image(systemName: favorite.isRecentGroup ? "clock.arrow.circlepath" : (favorite.isGroup ? "folder.fill" : (favorite.url != nil ? "globe" : "app")))
                            .frame(width: 16, height: 16)
                    }
                }.padding(.horizontal, 8).frame(maxWidth: .infinity, minHeight: 24)
                    .contentShape(Rectangle())
                    .opacity(slotDrag?.source == direction ? 0.5 : 1)
                    .overlay(GeometryReader { proxy in
                        let frame = proxy.frame(in: .named(slotSpace))
                        ExplorerSlotDragHandle(onChanged: { point in
                            updateSlotDrag(from: direction, at: CGPoint(x: frame.minX + point.x, y: frame.minY + point.y))
                        }, onEnded: { point in
                            finishSlotDrag(at: CGPoint(x: frame.minX + point.x, y: frame.minY + point.y))
                        }, onCancel: { slotDrag = nil; dropTarget = nil }, onClick: { if compact && !editingPreview { previewEditing = direction } })
                            .allowsHitTesting(!editingPreview)
                    })
                    .help("Drag \(favorite.name) to move or swap slots")
                    .accessibilityIdentifier("explorer-slot-\(direction.rawValue)")
            } else {
                Text("Empty slot").font(.caption).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 24)
                    .contentShape(Rectangle()).onTapGesture { if compact && !editingPreview { previewEditing = direction } }
            }
            if favorite != nil {
                HStack(spacing: 12) {
                    if favorite?.isGroup == true {
                        Button(favorite?.hasDeepChoices == true ? "Edit deep swipe" : "Edit HUD layer") {
                            if let favorite, favorite.isWindowManager {
                                tileLayerSnapshot = favorite
                                tileLayerOwnerID = selectedLayerID
                                editingTileLayers = groupPath + [direction]
                            } else { groupPath.append(direction) }
                        }
                    }
                    Button("Remove") {
                        if favorite?.isPureGroup == true { removingGroupPath = groupPath + [direction] }
                        else { edit { $0.setFavorite(nil, at: direction, in: groupPath) } }
                    }
                }.font(.caption2).buttonStyle(.link)
            }
        }.frame(maxWidth: .infinity).frame(height: 88)
            .popover(isPresented: Binding(get: { compact && !editingPreview && previewEditing == direction }, set: { if !$0 { previewEditing = nil } })) {
                tilePopover(direction)
            }
            .background(dropTarget == direction ? Color.teal.opacity(0.14) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(dropTarget == direction ? Color.teal : .clear, lineWidth: 2))
            .background(GeometryReader { proxy in
                Color.clear.preference(key: ExplorerSlotFramesKey.self, value: [direction: proxy.frame(in: .named(slotSpace))])
            })
    }

    /// SwiftUI Menu, Button and Toggle render as native macOS menu controls.
    /// Shared by Settings and the HUD's inline editor.
    @ViewBuilder private func assignmentMenu(_ direction: ExplorerSlot, favorite: AppExplorerFavorite?) -> some View {
        Menu {
            Button(favorite?.shortcut != nil ? "Edit action…" : "Assign macro or keystroke…", systemImage: "keyboard") {
                editingShortcutPath = groupPath + [direction]
            }
        } label: { Label("Keybindings and Macros", systemImage: "keyboard") }
        Menu {
            Button("Choose app…", systemImage: "app") { editingApplicationPath = groupPath + [direction] }
            Button(favorite?.url != nil ? "Edit URL…" : "Open URL…", systemImage: "globe") { editingURLPath = groupPath + [direction] }
            Button("Import Chrome or Safari bookmarks…", systemImage: "book.closed") {
                importingBookmarks = true
            }
            .disabled(isRecentGroup || availableBookmarkSlots.isEmpty)
            if let favorite, favorite.bundleID != nil {
                Divider()
                Toggle("Show this app’s windows", isOn: Binding(get: { favorite.showsWindows == true }, set: { enabled in
                    var updated = favorite; updated.showsWindows = enabled
                    edit { $0.setFavorite(updated, at: direction, in: groupPath) }
                }))
            }
        } label: { Label("App launches", systemImage: "app") }
        Menu {
            ForEach(ExplorerReservedGroup.allCases) { group in
                Button(group.title, systemImage: group.symbol) {
                    let tile = preservingHotkey(group.tile(at: direction, insideWindowManager: windowManagerOnly),
                        at: groupPath + [direction])
                    edit { $0.setFavorite(tile, at: direction, in: groupPath) }
                }.disabled(groupPath.count >= AppExplorerSettings.maximumGroupDepth && (group != .windowManager || windowManagerOnly))
            }
        } label: { Label("Built-in HUD layers", systemImage: "square.stack.3d.up") }
        Button("Create HUD layer…", systemImage: "square.3.layers.3d") { editingGroupPath = groupPath + [direction] }
            .disabled(groupPath.count >= AppExplorerSettings.maximumGroupDepth)
        Divider()
        Menu {
            Menu("Resize window") {
                windowActionButton(.maximize, at: direction)
                Divider()
                ForEach(ExplorerWindowLayout.allCases, id: \.self) { layout in
                    Menu(layout.title) {
                        ForEach(SwipeDirection.allCases, id: \.self) { placementDirection in
                            let placement = ExplorerWindowPlacement(direction: placementDirection, layout: layout)
                            Button(placement.title) {
                                edit { $0.setFavorite(preservingHotkey(AppExplorerFavorite(direction: direction, name: placement.title,
                                    windowPlacement: placement), at: groupPath + [direction]), at: direction, in: groupPath) }
                            }
                        }
                    }
                }
            }
            Menu("Full screen") {
                windowActionButton(.toggleFullScreen, at: direction)
                windowActionButton(.exitFullScreen, at: direction)
            }
            Divider()
            windowActionButton(.minimize, at: direction)
            windowActionButton(.closeWindow, at: direction)
        } label: { Label("Window management", systemImage: "macwindow") }
        Menu {
            ForEach(AppExplorerAction.macOSCommands, id: \.self) { action in
                windowActionButton(action, at: direction)
            }
        } label: { Label("Mac commands", systemImage: "macbook") }
        Button("Media controls", systemImage: "speaker.wave.2.fill") {
            edit { $0.setFavorite(preservingHotkey(AppExplorerFavorite(direction: direction, name: "Media Controls", action: .mediaControls),
                at: groupPath + [direction]), at: direction, in: groupPath) }
        }
    }

    private func windowActionButton(_ action: AppExplorerAction, at direction: ExplorerSlot, closeEditor: Bool = false) -> some View {
        Button(action.title, systemImage: action.symbol) {
            edit { $0.setFavorite(preservingHotkey(AppExplorerFavorite(direction: direction, name: action.title, action: action),
                at: groupPath + [direction]), at: direction, in: groupPath) }
            if closeEditor { previewEditing = nil }
        }
    }

    private func updateSlotDrag(from source: ExplorerSlot, at point: CGPoint) {
        if slotDrag == nil { slotDrag = ExplorerSlotDrag(source: source, path: groupPath, settings: settings) }
        guard let drag = slotDrag, drag.path == groupPath, drag.snapshot == settings else {
            dropTarget = nil
            return
        }
        let target = slotFrames.first { $0.value.contains(point) }?.key
        dropTarget = target == source ? nil : target
    }

    private func finishSlotDrag(at point: CGPoint) {
        defer { slotDrag = nil; dropTarget = nil }
        guard let drag = slotDrag,
              let target = slotFrames.first(where: { $0.value.contains(point) })?.key else { return }
        var next = settings
        guard drag.apply(to: target, in: groupPath, settings: &next) else { return }
        guard save(next) else { return }
        groupError = nil
    }

    private func recentSlot(_ direction: ExplorerSlot) -> some View {
        let order = ExplorerSlot.slots(settings.count(at: groupPath)).sorted { ($0.angle + 180).truncatingRemainder(dividingBy: 360) < ($1.angle + 180).truncatingRemainder(dividingBy: 360) }
        let rank = (order.firstIndex(of: direction) ?? 0) + 1
        return VStack(spacing: 5) {
            Text(direction.title).font(.caption).foregroundStyle(.secondary)
            Text("\(rank)").font(.title2.weight(.semibold)).foregroundStyle(.teal)
            Text(rank == 1 ? "Most recent" : "Recent app \(rank)").font(.caption)
        }.frame(maxWidth: .infinity).frame(height: 88)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    }

    @discardableResult private func saveBase(_ settings: AppExplorerSettings) -> Bool {
        if let configurationOverride {
            configurationOverride.wrappedValue = settings
            guard configurationOverride.wrappedValue == settings else {
                groupError = "Not saved: the tile moved or the full Explorer configuration exceeds its nesting or slot limits."
                return false
            }
        } else { store.settings.appExplorer = settings }
        return true
    }

    private func commitTransfer(_ next: AppExplorerSettings) -> Bool {
        guard next.hasValidFavorites else { return false }
        guard transferSave?(next) ?? saveBase(next) else { return false }
        groupError = nil
        return true
    }

    private func tileLayerBinding(_ path: [ExplorerSlot]) -> Binding<AppExplorerSettings> {
        Binding(get: {
            let tile = settings.favorite(at: path)
            if tile?.isWindowManager == true { return settings.windowEditor(at: path) }
            return AppExplorerSettings(actionBindings: tile?.actionBindings,
                favorites: tile?.children ?? [], holdShortcut: baseSettings.holdShortcut,
                holdLayers: tile?.holdLayers, slotCount: tile?.slotCount)
        }, set: { updated in
            guard tileLayerOwnerID == selectedLayerID, let expected = tileLayerSnapshot,
                  var tile = settings.favorite(at: path), tile == expected, let direction = path.last else {
                groupError = "This tile changed or moved while editing. Reopen its HUD layer editor."
                editingTileLayers = nil
                return
            }
            if tile.isWindowManager {
                var next = settings
                guard next.saveWindowEditor(updated, at: path), save(next) else { return }
                tileLayerSnapshot = next.favorite(at: path)
                return
            }
            tile.holdLayers = updated.holdLayers
            tile.actionBindings = updated.actionBindings
            if tile.isGroup { tile.children = updated.favorites; tile.slotCount = updated.slotCount }
            var next = settings
            guard next.setFavorite(tile, at: direction, in: Array(path.dropLast())), save(next) else { return }
            tileLayerSnapshot = tile
        })
    }

    private func edit(_ update: (inout AppExplorerSettings) -> Void) {
        var next = settings; update(&next)
        guard next.hasValidFavorites else { groupError = "Use the selected slot count, at most four nested HUD layers, and 256 total tiles."; return }
        _ = save(next)
    }

    private func saveScopeBinding(_ binding: ActionBinding) {
        var next = settings
        if groupPath.isEmpty {
            var values = next.actionBindings ?? []
            if let index = values.firstIndex(where: { $0.id == binding.id }) { values[index] = binding }
            else { values.append(binding) }
            next.actionBindings = values
        } else if let slot = groupPath.last, var group = next.favorite(at: groupPath) {
            var values = group.actionBindings ?? []
            if let index = values.firstIndex(where: { $0.id == binding.id }) { values[index] = binding }
            else { values.append(binding) }
            group.actionBindings = values
            guard next.setFavorite(group, at: slot, in: Array(groupPath.dropLast())) else { return }
        }
        _ = save(next)
    }

    private func openGroupHotkeys() {
        guard !groupPath.isEmpty, let group = settings.favorite(at: groupPath) else { return }
        groupHotkeysSnapshot = group
        groupHotkeysOwnerID = selectedLayerID
        editingGroupHotkeys = groupPath
    }

    /// Shared by the sheet and the native empty-group save regression.
    @discardableResult func saveGroupHotkeyDraft(_ updated: ExplorerHoldLayer, at path: [ExplorerSlot],
                                                  ownerID: UUID?, snapshot: AppExplorerFavorite) -> Bool {
        guard ownerID == selectedLayerID,
              var live = settings.favorite(at: path), live == snapshot,
              let direction = path.last else {
            groupError = "This HUD layer changed while editing. Reopen its hotkeys."
            return false
        }
        live.children = mergingActionHotkeys(from: updated.favorites, into: live.children ?? [])
        live.actionBindings = updated.actionBindings
        var next = settings
        guard next.setFavorite(live, at: direction, in: Array(path.dropLast())),
              save(next) else { return false }
        groupError = nil
        return true
    }

    private func tileBindingAction(_ favorite: AppExplorerFavorite, at direction: ExplorerSlot) -> BindingAction? {
        if favorite.isWindowManager {
            guard windowOwnerPath == nil else { return nil }
            return BindingAction(kind: .hudLayer, hudPath: [],
                windowOwnerPath: (transferPath + [.group(direction)]).map(\.token), name: favorite.name)
        }
        if favorite.isPureGroup {
            return BindingAction(kind: .hudLayer,
                hudPath: (transferPath + [.group(direction)]).map(\.token),
                windowOwnerPath: windowOwnerPath?.map(\.token), name: favorite.name)
        }
        return BindingAction.from(favorite: favorite)
    }

    private func preservingHotkey(_ replacement: AppExplorerFavorite, at path: [ExplorerSlot]) -> AppExplorerFavorite {
        var replacement = replacement
        if replacement.activationShortcut == nil {
            replacement.activationShortcut = settings.favorite(at: path)?.activationShortcut
        }
        if replacement.actionBindings == nil {
            replacement.actionBindings = settings.favorite(at: path)?.actionBindings
        }
        if replacement.children == nil, let current = settings.favorite(at: path), current.hasDeepChoices {
            replacement.children = current.children
            replacement.slotCount = current.slotCount
        }
        return replacement
    }

    private func mergingActionHotkeys(from edited: [AppExplorerFavorite],
                                      into live: [AppExplorerFavorite]) -> [AppExplorerFavorite] {
        live.map { liveTile in
            guard let editedTile = edited.first(where: { $0.direction == liveTile.direction }) else { return liveTile }
            var liveDestination = liveTile
            var editedDestination = editedTile
            liveDestination.activationShortcut = nil
            editedDestination.activationShortcut = nil
            guard liveDestination == editedDestination else { return liveTile }
            var result = liveTile
            result.activationShortcut = editedTile.activationShortcut
            return result
        }
    }

    @discardableResult private func save(_ settings: AppExplorerSettings) -> Bool {
        var next = settings
        if let selectedLayerID {
            next = baseSettings
            guard let index = next.holdLayers?.firstIndex(where: { $0.id == selectedLayerID }) else { groupError = "This layer was removed. Select another layer."; return false }
            next.holdLayers?[index].favorites = settings.favorites
            next.holdLayers?[index].slotCount = settings.slotCount
            next.holdLayers?[index].actionBindings = settings.actionBindings
        }
        guard next.hasValidFavorites else { groupError = "Use unique hold keys and stay within the 16-layer / 256-slot limits."; return false }
        guard saveBase(next) else { return false }
        groupError = nil
        return true
    }

    static func applicationIcon(for favorite: AppExplorerFavorite?) -> NSImage? {
        guard let favorite, !favorite.isGroup, favorite.url == nil, let bundleID = favorite.bundleID,
              let url = ExplorerApplicationCatalog.applicationURL(for: bundleID) else { return nil }
        // Native menu labels use NSImage's intrinsic size, not just the SwiftUI
        // frame. Copy before sizing so the workspace's cached icon is untouched.
        let icon = NSWorkspace.shared.icon(forFile: url.path).copy() as? NSImage
        icon?.size = NSSize(width: 16, height: 16)
        return icon
    }
}

/// Gives first-click tile actions equal visual weight while keeping native menu behavior.
private struct ExplorerTileActionLabel: View {
    let title: String
    let detail: String
    let systemImage: String
    var compact = false
    var showsMenu = false

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28, height: 28)
                .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.primary)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Image(systemName: showsMenu ? "chevron.down" : "arrow.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: compact ? 52 : 62, alignment: .leading)
        .contentShape(Rectangle())
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.09))
        }
    }
}

/// A single destination picker works in Settings and in the HUD's inline editor.
struct ExplorerTileTransferEditor: View {
    let transfer: ExplorerTileTransfer
    var onSave: ([ExplorerTilePathStep], ExplorerSlot, Bool) -> String?
    var onCancel: () -> Void
    @State private var destination: [ExplorerTilePathStep]
    @State private var target: ExplorerSlot?
    @State private var copy = false
    @State private var error: String?

    init(transfer: ExplorerTileTransfer,
         onSave: @escaping ([ExplorerTilePathStep], ExplorerSlot, Bool) -> String?, onCancel: @escaping () -> Void) {
        self.transfer = transfer; self.onSave = onSave; self.onCancel = onCancel
        _destination = State(initialValue: transfer.source)
    }

    private var containers: [ExplorerTileContainer] {
        transfer.snapshot.tileContainers().filter { !$0.id.starts(with: transfer.source + [.group(transfer.slot)]) }
    }
    private var selected: ExplorerTileContainer? { containers.first { $0.id == destination } }
    private var displaced: AppExplorerFavorite? { selected?.favorites.first { $0.direction == target } }
    private var validation: String? {
        guard let target else { return "Choose a destination slot." }
        var preview = transfer.snapshot
        return transfer.apply(to: destination, slot: target, copy: copy, settings: &preview)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Send \(transfer.favorite?.name ?? "tile") to a HUD layer", systemImage: "square.on.square")
                .font(.title2.weight(.semibold))
            Text("The tile and any HUD layers beneath it travel together.")
                .font(.callout).foregroundStyle(.secondary)
            Picker("Operation", selection: $copy) {
                Text("Move / swap").tag(false)
                Text("Copy").tag(true)
            }.pickerStyle(.segmented).labelsHidden()
            Picker("Destination HUD layer", selection: $destination) {
                ForEach(containers) { container in Text(container.title).tag(container.id) }
            }.accessibilityIdentifier("explorer-transfer-container")
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 10) {
                    ForEach(ExplorerSlot.slots(selected?.count ?? 8), id: \.self) { slot in
                        let occupant = selected?.favorites.first { $0.direction == slot }
                        let isSource = destination == transfer.source && slot == transfer.slot
                        Button { target = slot; error = nil } label: {
                            VStack(spacing: 6) {
                                Text(slot.title).font(.caption).foregroundStyle(.secondary)
                                Image(systemName: occupant?.isGroup == true ? "folder" : (occupant == nil ? "plus" : "square.on.square"))
                                Text(isSource ? "Current tile" : occupant?.name ?? "Empty")
                                    .font(.caption.weight(.medium)).lineLimit(2)
                            }.frame(maxWidth: .infinity).frame(height: 78)
                                .background(target == slot ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(target == slot ? Color.accentColor : Color.clear, lineWidth: 2))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(isSource || (copy && occupant != nil))
                            .accessibilityLabel("\(slot.title): \(occupant?.name ?? "Empty")")
                            .accessibilityIdentifier("explorer-transfer-slot-\(slot.rawValue)")
                    }
                }.padding(3)
            }.frame(height: 182)
            Text(error ?? validation ?? (copy ? "Copy to this empty slot. The original stays where it is."
                : displaced.map { "Swap with \($0.name). It will move to the source slot; nothing is deleted." }
                    ?? "Move to this empty slot. The source slot will become empty."))
                .font(.callout).foregroundStyle(error == nil ? Color.secondary : Color.red)
                .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
            HStack {
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button(copy ? "Copy tile" : displaced == nil ? "Move tile" : "Swap tiles") {
                    if let target { error = onSave(destination, target, copy) }
                }.keyboardShortcut(.defaultAction).disabled(validation != nil)
                    .accessibilityIdentifier("explorer-transfer-save")
            }
        }.padding(24).frame(width: 570)
            .onChange(of: destination) { _, _ in target = nil; error = nil }
            .onChange(of: copy) { _, _ in target = nil; error = nil }
    }
}

private struct ExplorerSlotFramesKey: PreferenceKey {
    static let defaultValue: [ExplorerSlot: CGRect] = [:]
    static func reduce(value: inout [ExplorerSlot: CGRect], nextValue: () -> [ExplorerSlot: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct ExplorerSlotDragHandle: NSViewRepresentable {
    var onChanged: (CGPoint) -> Void
    var onEnded: (CGPoint) -> Void
    var onCancel: () -> Void
    var onClick: () -> Void = {}

    func makeNSView(context: Context) -> ExplorerSlotDragView { ExplorerSlotDragView() }
    func updateNSView(_ view: ExplorerSlotDragView, context: Context) {
        view.onChanged = onChanged; view.onEnded = onEnded; view.onCancel = onCancel; view.onClick = onClick
    }
}

// Native mouse capture keeps a drag attached to its original label as it crosses
// the grid. Menu buttons remain separate, so pressing a label never opens a menu.
private final class ExplorerSlotDragView: NSView {
    var onChanged: (CGPoint) -> Void = { _ in }
    var onEnded: (CGPoint) -> Void = { _ in }
    var onCancel: () -> Void = {}
    var onClick: () -> Void = {}
    private var start: CGPoint?
    private var dragging = false
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func mouseDown(with event: NSEvent) {
        start = event.locationInWindow
        dragging = false
        window?.makeFirstResponder(self)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let point = event.locationInWindow
        guard dragging || hypot(point.x - start.x, point.y - start.y) >= 6 else { return }
        dragging = true
        onChanged(convert(point, from: nil))
    }
    override func mouseUp(with event: NSEvent) {
        guard start != nil else { return }
        let commit = dragging
        start = nil; dragging = false
        if commit { onEnded(convert(event.locationInWindow, from: nil)) }
        else { onCancel(); onClick() }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { start = nil; dragging = false; onCancel() }
        else { super.keyDown(with: event) }
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil, start != nil { start = nil; dragging = false; onCancel() }
        super.viewWillMove(toWindow: newWindow)
    }
}

/// Uses the actual HUD view and entry mapping; only its callbacks are different.
/// No controller, input monitor, app activation, or keyboard posting is started.
struct ExplorerHUDSettingsPreview: View {
    let settings: AppExplorerSettings
    let theme: ExplorerTheme
    let dictionary: [NamedHotkey]
    let groupPath: [ExplorerSlot]
    let layerName: String?
    @Binding var selection: ExplorerSlot
    var onBack: () -> Void
    var onDrag: (ExplorerSlot, ExplorerSlot?) -> Void
    var onDrop: (ExplorerSlot, ExplorerSlot?) -> Void
    var editingTile: Binding<ExplorerSlot?> = .constant(nil)
    var editor: ((ExplorerSlot) -> AnyView)? = nil
    @StateObject private var model = ExplorerModel()

    var body: some View {
        AppExplorerView(model: model, onSelect: { slot in
            if !model.showingRecents { selection = slot; if editor != nil { editingTile.wrappedValue = slot } }
        }, onCancel: {}, onBack: onBack, isPreview: true,
            onPreviewDrag: { source, target in editingTile.wrappedValue = nil; model.selected = target; onDrag(source, target) },
            onPreviewDrop: { source, target in onDrop(source, target); model.selected = selection })
            .accessibilityIdentifier("hud-layout-preview")
            .overlayPreferenceValue(ExplorerTileAnchors.self) { anchors in
                GeometryReader { proxy in
                    if let slot = editingTile.wrappedValue, let anchor = anchors[slot], let editor {
                        let rect = proxy[anchor]
                        Color.clear.frame(width: rect.width, height: rect.height)
                            .popover(isPresented: Binding(get: { editingTile.wrappedValue == slot }, set: { if !$0 { editingTile.wrappedValue = nil } })) {
                                editor(slot)
                            }
                            .position(x: rect.midX, y: rect.midY)
                    }
                }
            }
            .onAppear(perform: refresh)
            .onChange(of: settings) { _, _ in refresh() }
            .onChange(of: theme) { _, _ in refresh() }
            .onChange(of: dictionary) { _, _ in refresh() }
            .onChange(of: groupPath) { _, _ in refresh() }
            .onChange(of: layerName) { _, _ in refresh() }
            .onChange(of: selection) { _, selected in model.selected = selected }
    }

    private func refresh() {
        model.theme = theme
        model.animationsEnabled = settings.resolvedAnimationsEnabled
        model.mode = .favorites
        model.slotCount = settings.count(at: groupPath)
        model.layerName = layerName
        model.groupNames = groupPath.indices.compactMap { settings.favorite(at: Array(groupPath.prefix($0 + 1)))?.name }
        model.groupDirections = groupPath
        model.groupSlotCounts = groupPath.indices.map { settings.count(at: Array(groupPath.prefix($0))) }
        model.showingRecents = settings.favorite(at: groupPath)?.isRecentGroup == true
        model.selected = model.showingRecents ? nil : selection
        if model.showingRecents {
            let order = ExplorerSlot.slots(model.slotCount).sorted {
                ($0.angle + 180).truncatingRemainder(dividingBy: 360) < ($1.angle + 180).truncatingRemainder(dividingBy: 360)
            }
            model.entries = order.enumerated().map { index, slot in
                ExplorerEntry(direction: slot, bundleID: nil, name: index == 0 ? "Most recent app" : "Recent app \(index + 1)",
                    icon: NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil), url: nil)
            }
            model.message = "Recent apps fill these positions at runtime · center goes back"
        } else {
            model.entries = (settings.favorites(at: groupPath) ?? []).map {
                AppExplorerController.makeEntry($0, depth: groupPath.count, dictionary: dictionary)
            }
            model.message = "Select a tile to edit · drag to move or swap"
        }
    }
}

struct ExplorerInlineEditor: View {
    static let preferredWidth: CGFloat = 760
    @ObservedObject var store: SettingsStore
    var groupPath: [ExplorerSlot]
    var onGroupPathChange: ([ExplorerSlot]) -> Void
    var onDone: () -> Void
    var configurationOverride: Binding<AppExplorerSettings>? = nil
    var windowManagerOnly = false
    var windowOwnerPath: [ExplorerTilePathStep]? = nil
    var contentWidth: CGFloat = Self.preferredWidth
    var contentHeight: CGFloat = 760
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label(windowManagerOnly ? "Edit Window Manager" : "Edit HUD", systemImage: "pencil").font(.title3.weight(.semibold))
                Spacer()
                Button("Done", action: onDone).keyboardShortcut(.defaultAction)
            }
            ScrollView {
                AppExplorerSettingsView(store: store, groupPath: groupPath, compact: false,
                    configurationOverride: configurationOverride, windowManagerOnly: windowManagerOnly,
                    windowOwnerPath: windowManagerOnly ? (windowOwnerPath ?? []) : nil,
                    onGroupPathChange: onGroupPathChange)
                    .padding(.horizontal, 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Text("Changes save automatically · taps click while editing · swipe shortcuts resume when you finish")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(26).frame(width: contentWidth, height: contentHeight)
            .environment(\.hotkeyDictionary, store.settings.resolvedHotkeyDictionary)
            .environment(\.hudActionLayers, store.settings.appExplorer?.holdLayers ?? [])
            .environment(\.hudActionDestinations, store.settings.appExplorer?.hudActionDestinations() ?? [])
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
    }
}

struct ExplorerGroupNameEditor: View {
    @State var name: String
    var isNew: Bool
    var onSave: (String) -> Void
    var onCancel: () -> Void
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(isNew ? "New HUD layer" : "Rename HUD layer", systemImage: "square.3.layers.3d").font(.headline)
            TextField("HUD layer name", text: $name).textFieldStyle(.roundedBorder)
            Text("Name this HUD layer. Its tiles can be assigned actions or automatically filled with recent apps.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button(isNew ? "Create HUD layer" : "Save") { onSave(trimmedName) }
                    .keyboardShortcut(.defaultAction).disabled(trimmedName.isEmpty || trimmedName.count > 512)
            }
        }.padding(24).frame(width: 400).background(Color(nsColor: .windowBackgroundColor))
    }
}

struct ExplorerShortcutEditor: View {
    @Environment(\.hotkeyDictionary) private var dictionary
    let direction: ExplorerSlot
    @State var name: String
    @State var shortcut: RecordedShortcut?
    var onSave: (AppExplorerFavorite) -> Void
    var onCancel: () -> Void
    @State private var action: TapAction = .shortcut

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("\(direction.title) · Macro, keystroke or HUD layer", systemImage: "keyboard").font(.headline)
            TextField("Name (optional)", text: $name).textFieldStyle(.roundedBorder)
            TapActionEditor(title: "Shortcut to send", action: $action, shortcut: $shortcut, keyboardOnly: true)
            if let shortcut, dictionary.label(for: shortcut) != nil {
                Text("HUD label: \(dictionary.title(for: shortcut))").font(.caption).foregroundStyle(.secondary)
            }
            Text("Swipe to this slot and lift to send the shortcut to the app you were using. Use ••• → Set shortcut manually if another app intercepts the keys while recording.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    guard let shortcut, shortcut.isValidExplorerShortcut else { return }
                    let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    let favorite = AppExplorerFavorite(direction: direction, name: title.isEmpty ? shortcut.displayName : title, shortcut: shortcut)
                    guard favorite.isValidDestination else { return }
                    onSave(favorite)
                }.keyboardShortcut(.defaultAction).disabled(shortcut?.isValidExplorerShortcut != true || name.count > 512)
            }
        }.padding(24).frame(width: 440).background(Color(nsColor: .windowBackgroundColor))
    }
}

struct ExplorerURLFavoriteEditor: View {
    let direction: ExplorerSlot
    @State var name: String
    @State var address: String
    @State var iconSymbol: String?
    var onSave: (AppExplorerFavorite) -> Void
    var onCancel: () -> Void

    init(direction: ExplorerSlot, name: String, address: String, iconSymbol: String? = nil,
         onSave: @escaping (AppExplorerFavorite) -> Void, onCancel: @escaping () -> Void) {
        self.direction = direction
        _name = State(initialValue: name)
        _address = State(initialValue: address)
        _iconSymbol = State(initialValue: iconSymbol)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    private var validURL: URL? {
        AppExplorerFavorite.webURL(address.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    private let iconColumns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 8)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("\(direction.title) · Web favorite", systemImage: "globe").font(.headline)
            TextField("Name (optional)", text: $name)
            TextField("https://example.com", text: $address)
            Text("Use a full http:// or https:// address. Opens in your default browser; the host name is used if you leave the name blank.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !address.isEmpty && validURL == nil {
                Text("Enter a valid web URL without spaces or an embedded username/password.")
                    .font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 12) {
                    WebsiteFavicon(url: validURL, size: 34, symbolName: iconSymbol)
                        .frame(width: 44, height: 44)
                        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(iconSymbol == nil ? "Automatic site icon" : "Custom icon")
                            .font(.system(size: 12, weight: .semibold))
                        Text(iconSymbol == nil ? "Uses the site's favicon when available." : "Overrides the site's favicon on this HUD tile.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                LazyVGrid(columns: iconColumns, spacing: 8) {
                    iconChoice(symbol: nil, title: "Automatic favicon")
                    ForEach(WebsiteIconCatalog.choices, id: \.symbol) { choice in
                        iconChoice(symbol: choice.symbol, title: choice.title)
                    }
                }
            }
            .padding(12)
            .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))

            Text("URLs and your icon choice are included in settings export and cloud sync. Avoid private sign-in links or URLs containing secrets.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    guard let url = validURL else { return }
                    let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    onSave(AppExplorerFavorite(direction: direction, name: title.isEmpty ? (url.host ?? "Website") : title,
                        url: url.absoluteString, iconSymbol: iconSymbol))
                }.keyboardShortcut(.defaultAction).disabled(validURL == nil || name.count > 512)
            }
        }.textFieldStyle(.roundedBorder).padding(24).frame(width: 440)
            .background(Color(nsColor: .windowBackgroundColor))
    }

    private func iconChoice(symbol: String?, title: String) -> some View {
        let selected = iconSymbol == symbol
        return Button { iconSymbol = symbol } label: {
            Group {
                if let symbol { Image(systemName: symbol) }
                else { Image(systemName: "wand.and.stars") }
            }
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            .frame(maxWidth: .infinity).frame(height: 32)
            .background(selected ? Color.accentColor.opacity(0.13) : Color.primary.opacity(0.035),
                        in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7)
                .stroke(selected ? Color.accentColor.opacity(0.65) : Color.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
