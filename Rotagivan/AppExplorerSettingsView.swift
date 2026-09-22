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
            GroupBox("Reserved Groups") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Built-in groups, always available from any tile’s ••• → Reserved Groups menu.")
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
                Text("Reserved Groups · \(group.summary)").font(.callout).foregroundStyle(.secondary)
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
            Text("Assign this group to a tile using ••• → Reserved Groups → \(group.title).")
            if group == .actions {
                Text("Each added Actions group starts with these shortcuts. Edit or rearrange its tiles independently. Commands go to the app you were using before opening the HUD; support varies by app.")
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
                Text("This group fills itself with running apps. The most recent app starts on the left, followed by the top-left, then clockwise. The current app is excluded. Tap the center to return to the parent group.")
                Text("Its contents update on this Mac. Add it anywhere in your HUD, including inside another group; edit the assigned group to change its capacity or name.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct WindowManagerSettingsView: View {
    @ObservedObject var store: SettingsStore
    @State private var error: String?
    @State private var shortcutAction: TapAction = .shortcut
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
            Text("Customize this group like App Explorer. Each tile can place the window, run a command, or open another group. Drag tiles to rearrange them; use layers for alternate layouts.")
                .font(.callout).foregroundStyle(.secondary)
            AppExplorerSettingsView(store: store, configurationOverride: Binding(get: {
                explorer.windowEditor()
            }, set: { updated in
                var next = explorer
                guard next.saveWindowEditor(updated) else { error = "This group exceeds the nesting or tile limits."; return }
                store.settings.appExplorer = next; error = nil
            }), scopeTitle: "Window Manager", windowManagerOnly: true, windowApplet: true)
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
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
    }
}

struct AppExplorerSettingsView: View {
    @ObservedObject var store: SettingsStore
    @State private var editingURLPath: [ExplorerSlot]?
    @State private var editingShortcutPath: [ExplorerSlot]?
    @State private var selectedLayerID: UUID?
    @State private var editingLayer: ExplorerHoldLayer?
    @State private var creatingLayer = false
    @State private var removingLayer = false
    @State private var editingTileLayers: [ExplorerSlot]?
    @State private var tileLayerSnapshot: AppExplorerFavorite?
    @State private var tileLayerOwnerID: UUID?
    @State private var inheritTileLayers = false
    @State private var editingApplicationPath: [ExplorerSlot]?
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
    private let transferRoot: (() -> AppExplorerSettings)?
    private let transferSave: ((AppExplorerSettings) -> Bool)?
    private let transferPrefix: [ExplorerTilePathStep]
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
    private var isRecentGroup: Bool { settings.favorite(at: groupPath)?.isRecentGroup == true }
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
    var compact = false
    var onGroupPathChange: (([ExplorerSlot]) -> Void)? = nil

    init(store: SettingsStore, groupPath: [ExplorerSlot] = [], compact: Bool = false, initialLayerID: UUID? = nil,
         configurationOverride: Binding<AppExplorerSettings>? = nil, scopeTitle: String? = nil, windowManagerOnly: Bool = false, windowApplet: Bool = false,
         transferRoot: (() -> AppExplorerSettings)? = nil, transferSave: ((AppExplorerSettings) -> Bool)? = nil,
         transferPrefix: [ExplorerTilePathStep] = [],
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
        self.onGroupPathChange = onGroupPathChange
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let scopeTitle {
                Label("Layers for \(scopeTitle)", systemImage: "square.3.layers.3d").font(.headline)
                Text(windowApplet ? "These layers belong to Window Manager. Hold a key temporarily, or tap a toggle key to switch tiles until you close the applet." : "These keys work only inside this tile. Hold temporarily or tap to toggle; leaving the tile returns to its default.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !windowApplet && !windowManagerOnly {
                Toggle("Use tile-specific layers", isOn: Binding(get: { baseSettings.holdLayers != nil }, set: { custom in
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
            if !compact && selectedLayerID == nil && scopeTitle == nil {
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
            HStack {
                if compact && scopeTitle == nil {
                    Menu {
                        Picker("Theme", selection: themeBinding) {
                            ForEach(ExplorerTheme.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        Toggle("Animate HUD feedback", isOn: animationBinding)
                        Toggle("Put mouse in center of selected app", isOn: centerCursorBinding)
                    } label: { Image(systemName: "paintpalette") }
                        .menuStyle(.borderlessButton).fixedSize().help("Explorer appearance")
                }
                Picker(windowApplet ? "Window layer" : scopeTitle == nil ? "Explorer-wide layer" : "Tile layer", selection: $selectedLayerID) {
                    Text("Default").tag(nil as UUID?)
                    ForEach(baseSettings.holdLayers ?? []) { layer in Text(layer.name).tag(Optional(layer.id)) }
                }
                Button("Add layer") {
                    creatingLayer = true
                    let y = RecordedShortcut(keyCode: 16, modifiers: 0, keyLabel: "Y")
                    let used = (baseSettings.holdLayers ?? []).contains { $0.holdShortcut?.keyCode == y.keyCode && $0.holdShortcut?.modifiers == 0 }
                    editingLayer = ExplorerHoldLayer(name: "New layer", holdShortcut: used ? nil : y, favorites: settings.favorites, windowLayout: .thirds, slotCount: settings.slotCount, windowTilesConfigured: windowManagerOnly ? true : nil)
                }.disabled((baseSettings.holdLayers ?? []).count >= 16 || (scopeTitle != nil && baseSettings.holdLayers == nil))
                if let layer = baseSettings.holdLayers?.first(where: { $0.id == selectedLayerID }) {
                    Button("Edit…") { creatingLayer = false; editingLayer = layer }
                    Button("Remove", role: .destructive) { removingLayer = true }
                }
            }.font(.subheadline)
            if scopeTitle == nil && compact {
                Text("For keys that apply to just one group or Window Manager, use that tile’s ••• → Tile layers…")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if windowManagerOnly {
                Text("Slot direction and window position are independent. Use ••• → Window management → Resize window to assign any position and size.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Picker("Slots in this group / layer", selection: Binding(get: { settings.count(at: groupPath) }, set: { count in
                var next = settings
                guard next.resize(to: count, at: groupPath) else {
                    groupError = "Remove some tiles before choosing fewer slots. Your existing tiles have been kept."; return
                }
                _ = save(next)
            })) { ForEach([4, 8, 12, 16], id: \.self) { Text("\($0)").tag($0) } }
                .pickerStyle(.segmented)
            HStack(spacing: 5) {
                Button("Favorites") { groupPath = [] }.buttonStyle(.link)
                ForEach(groupPath.indices, id: \.self) { index in
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    Button(settings.favorite(at: Array(groupPath.prefix(index + 1)))?.name ?? "Group") {
                        groupPath = Array(groupPath.prefix(index + 1))
                    }.buttonStyle(.link).lineLimit(1)
                }
                Spacer(minLength: 4)
                if !groupPath.isEmpty {
                    Button("Rename…") { editingGroupPath = groupPath }
                }
            }.font(.subheadline.weight(.medium))
            if !groupPath.isEmpty {
                Picker("Group contents", selection: Binding(get: {
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
                    })
                    .padding(.top, -20)
                    .frame(maxWidth: .infinity)
                if !isRecentGroup {
                    Text("Selected tile").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    slot(previewSelection)
                }
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
                                        Text(groupPath.isEmpty ? "Favorites" : "Back").font(.caption)
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
                : "Select a tile in the preview to edit it below. Drag tiles to move or swap. Use ••• → Move or copy… to move a whole group between layers. Preview clicks never launch apps or run actions.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .overlay(alignment: .bottomLeading) {
            if let groupError { Text(groupError).font(.caption).foregroundStyle(.red).padding(6).background(.regularMaterial) }
        }
        .sheet(item: $tileTransfer) { transfer in
            ExplorerTileTransferEditor(transfer: transfer, onSave: { destination, slot, copy in
                var next = transferSettings
                if let error = transfer.apply(to: destination, slot: slot, copy: copy, settings: &next) { return error }
                guard commitTransfer(next) else { return "The configuration changed or could not be saved. Reopen Move or copy." }
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
                            }, transferPrefix: tile.isWindowManager ? [] : transferPrefix + (selectedLayerID.map { [.layer($0)] } ?? []) + path.map { .group($0) })).padding(24)
                    }
                    Button("Done") { editingTileLayers = nil }.keyboardShortcut(.cancelAction).padding()
                }.frame(width: 660, height: 620)
            }
        }
        .sheet(item: $editingLayer) { layer in
            ExplorerHoldLayerEditor(layer: layer, settings: baseSettings, onSave: { updated in
                var next = baseSettings
                var layers = next.holdLayers ?? []
                if let index = layers.firstIndex(where: { $0.id == updated.id }) {
                    // Preserve slot edits that may have arrived via sync while the sheet was open.
                    var merged = updated; merged.favorites = layers[index].favorites; layers[index] = merged
                } else {
                    guard creatingLayer else { groupError = "This layer was removed while editing."; editingLayer = nil; return }
                    layers.append(updated)
                }
                next.holdLayers = layers
                guard next.hasValidFavorites else { groupError = "Use unique hold keys and stay within the 16-layer / 256-slot limits."; return }
                guard saveBase(next) else { return }
                selectedLayerID = updated.id; groupPath = []; editingLayer = nil; groupError = nil
            }, onCancel: { editingLayer = nil }, supportsDirectLaunch: configurationOverride == nil && !windowManagerOnly)
        }
        .confirmationDialog("Remove this Explorer layer and all its slots?", isPresented: $removingLayer, titleVisibility: .visible) {
            Button("Remove layer", role: .destructive) {
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
                    guard next.setFavorite(favorite, at: direction, in: Array(path.dropLast())), next.hasValidFavorites else {
                        groupError = "The destination group changed. Reopen the picker and try again."
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
                        guard next.setFavorite(favorite, at: direction, in: Array(path.dropLast())), next.hasValidFavorites else {
                            groupError = "The destination group changed. Reopen the shortcut editor and try again."
                            editingShortcutPath = nil
                            return
                        }
                        guard save(next) else { return }
                        groupError = nil; editingShortcutPath = nil
                    }, onCancel: { editingShortcutPath = nil })
            }
        }
        .sheet(isPresented: Binding(get: { editingURLPath != nil }, set: { if !$0 { editingURLPath = nil } })) {
            if let path = editingURLPath, let direction = path.last {
                let favorite = settings.favorite(at: path)
                ExplorerURLFavoriteEditor(direction: direction,
                    name: favorite?.url != nil ? (favorite?.name ?? "") : "",
                    address: favorite?.url ?? "", onSave: { favorite in
                        edit { $0.setFavorite(favorite, at: direction, in: Array(path.dropLast())) }
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
                            groupError = "Groups support four levels and 256 total favorites. The parent group must still exist."
                            editingGroupPath = nil
                            return
                        }
                        guard save(next) else { return }
                        groupError = nil; editingGroupPath = nil
                        if !group.isWindowManager { groupPath = path }
                    }, onCancel: { editingGroupPath = nil })
            }
        }
        .confirmationDialog("Remove this group and all its favorites?", isPresented: Binding(get: { removingGroupPath != nil }, set: { if !$0 { removingGroupPath = nil } }), titleVisibility: .visible) {
            Button("Remove group", role: .destructive) {
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
        .onChange(of: selectedLayerID) { _, _ in groupPath = []; groupError = nil; slotDrag = nil; dropTarget = nil; previewDrag = nil }
        .onChange(of: baseSettings.holdLayers) { _, layers in
            if let selectedLayerID, layers?.contains(where: { $0.id == selectedLayerID }) != true { self.selectedLayerID = nil }
        }
        .onChange(of: groupPath) { _, path in previewDrag = nil; onGroupPathChange?(path) }
        .onChange(of: settings.count(at: groupPath)) { _, count in
            if !ExplorerSlot.slots(count).contains(previewSelection) { previewSelection = .up }
            previewDrag = nil
        }
        .onDisappear { slotDrag = nil; dropTarget = nil }
    }

    private func slot(_ direction: ExplorerSlot) -> some View {
        let favorite = favorites.first { $0.direction == direction }
        let icon = Self.applicationIcon(for: favorite)
        return VStack(spacing: 5) {
            HStack {
                Text(direction.title).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Menu {
                    if let favorite, favorite.supportsHoldLayers {
                        Button(favorite.isWindowManager ? "Edit Window Manager group…" : "Tile layers…") {
                            tileLayerSnapshot = favorite
                            tileLayerOwnerID = selectedLayerID
                            editingTileLayers = groupPath + [direction]
                        }
                        Divider()
                    }
                    if favorite?.isGroup == true {
                        if favorite?.isWindowManager != true { Button("Edit group…") { groupPath.append(direction) } }
                        Button("Rename group…") { editingGroupPath = groupPath + [direction] }
                    } else {
                        assignmentMenu(direction, favorite: favorite)
                    }
                    if favorite != nil {
                        Divider()
                        Button("Move or copy…") {
                            tileTransfer = ExplorerTileTransfer(snapshot: transferSettings, source: transferPath, slot: direction)
                        }
                        Menu("Move or swap with") {
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
                    } else if !favorite.isGroup, favorite.url != nil {
                        WebsiteFavicon(url: favorite.resolvedWebURL, size: 16)
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
                        }, onCancel: { slotDrag = nil; dropTarget = nil })
                    })
                    .help("Drag \(favorite.name) to move or swap slots")
                    .accessibilityIdentifier("explorer-slot-\(direction.rawValue)")
            } else {
                Text("Empty slot").font(.caption).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 24)
            }
            if favorite != nil {
                HStack(spacing: 12) {
                    if favorite?.isGroup == true {
                        Button("Edit group") {
                            if let favorite, favorite.isWindowManager {
                                tileLayerSnapshot = favorite
                                tileLayerOwnerID = selectedLayerID
                                editingTileLayers = groupPath + [direction]
                            } else { groupPath.append(direction) }
                        }
                    }
                    Button("Remove") {
                        if favorite?.isGroup == true { removingGroupPath = groupPath + [direction] }
                        else { edit { $0.setFavorite(nil, at: direction, in: groupPath) } }
                    }
                }.font(.caption2).buttonStyle(.link)
            }
        }.frame(maxWidth: .infinity).frame(height: 88)
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
        } label: { Label("Macros & keystrokes", systemImage: "keyboard") }
        Menu {
            Button("Choose app…", systemImage: "app") { editingApplicationPath = groupPath + [direction] }
            Button(favorite?.url != nil ? "Edit URL…" : "Open URL…", systemImage: "globe") { editingURLPath = groupPath + [direction] }
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
                    let tile = group.tile(at: direction, insideWindowManager: windowManagerOnly)
                    edit { $0.setFavorite(tile, at: direction, in: groupPath) }
                }.disabled(groupPath.count >= AppExplorerSettings.maximumGroupDepth && (group != .windowManager || windowManagerOnly))
            }
        } label: { Label("Reserved Groups", systemImage: "square.stack.3d.up") }
        Button("Create tile group…", systemImage: "folder.badge.plus") { editingGroupPath = groupPath + [direction] }
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
                                edit { $0.setFavorite(AppExplorerFavorite(direction: direction, name: placement.title,
                                    windowPlacement: placement), at: direction, in: groupPath) }
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
            windowActionButton(.appWindows, at: direction)
            windowActionButton(.minimize, at: direction)
            windowActionButton(.closeWindow, at: direction)
        } label: { Label("Window management", systemImage: "macwindow") }
        Button("Media controls", systemImage: "speaker.wave.2.fill") {
            edit { $0.setFavorite(AppExplorerFavorite(direction: direction, name: "Media Controls", action: .mediaControls), at: direction, in: groupPath) }
        }
    }

    private func windowActionButton(_ action: AppExplorerAction, at direction: ExplorerSlot) -> some View {
        Button(action.title, systemImage: action.symbol) {
            edit { $0.setFavorite(AppExplorerFavorite(direction: direction, name: action.title, action: action), at: direction, in: groupPath) }
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
            return AppExplorerSettings(favorites: tile?.children ?? [], holdShortcut: baseSettings.holdShortcut,
                holdLayers: tile?.holdLayers, slotCount: tile?.slotCount)
        }, set: { updated in
            guard tileLayerOwnerID == selectedLayerID, let expected = tileLayerSnapshot,
                  var tile = settings.favorite(at: path), tile == expected, let direction = path.last else {
                groupError = "This tile changed or moved while editing. Reopen its Tile layers editor."
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
            if tile.isGroup { tile.children = updated.favorites; tile.slotCount = updated.slotCount }
            var next = settings
            guard next.setFavorite(tile, at: direction, in: Array(path.dropLast())), save(next) else { return }
            tileLayerSnapshot = tile
        })
    }

    private func edit(_ update: (inout AppExplorerSettings) -> Void) {
        var next = settings; update(&next)
        guard next.hasValidFavorites else { groupError = "Use the selected slot count, at most four group levels, and 256 total favorites."; return }
        _ = save(next)
    }

    @discardableResult private func save(_ settings: AppExplorerSettings) -> Bool {
        var next = settings
        if let selectedLayerID {
            next = baseSettings
            guard let index = next.holdLayers?.firstIndex(where: { $0.id == selectedLayerID }) else { groupError = "This layer was removed. Select another layer."; return false }
            next.holdLayers?[index].favorites = settings.favorites
            next.holdLayers?[index].slotCount = settings.slotCount
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
            Label("Move or copy \(transfer.favorite?.name ?? "tile")", systemImage: "square.on.square")
                .font(.title2.weight(.semibold))
            Text("All nested tiles, group layouts, and custom layers travel together.")
                .font(.callout).foregroundStyle(.secondary)
            Picker("Operation", selection: $copy) {
                Text("Move / swap").tag(false)
                Text("Copy").tag(true)
            }.pickerStyle(.segmented).labelsHidden()
            Picker("To layer / group", selection: $destination) {
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

    func makeNSView(context: Context) -> ExplorerSlotDragView { ExplorerSlotDragView() }
    func updateNSView(_ view: ExplorerSlotDragView, context: Context) {
        view.onChanged = onChanged; view.onEnded = onEnded; view.onCancel = onCancel
    }
}

// Native mouse capture keeps a drag attached to its original label as it crosses
// the grid. Menu buttons remain separate, so pressing a label never opens a menu.
private final class ExplorerSlotDragView: NSView {
    var onChanged: (CGPoint) -> Void = { _ in }
    var onEnded: (CGPoint) -> Void = { _ in }
    var onCancel: () -> Void = {}
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
        let commit = dragging
        start = nil; dragging = false
        if commit { onEnded(convert(event.locationInWindow, from: nil)) }
        else { onCancel() }
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
    @StateObject private var model = ExplorerModel()

    var body: some View {
        AppExplorerView(model: model, onSelect: { slot in
            if !model.showingRecents { selection = slot }
        }, onCancel: {}, onBack: onBack, isPreview: true,
            onPreviewDrag: { source, target in model.selected = target; onDrag(source, target) },
            onPreviewDrop: { source, target in onDrop(source, target); model.selected = selection })
            .accessibilityIdentifier("hud-layout-preview")
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
    @ObservedObject var store: SettingsStore
    var groupPath: [ExplorerSlot]
    var onGroupPathChange: ([ExplorerSlot]) -> Void
    var onDone: () -> Void
    var configurationOverride: Binding<AppExplorerSettings>? = nil
    var windowManagerOnly = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label(windowManagerOnly ? "Edit Window Manager" : "Edit App Explorer", systemImage: "pencil").font(.title3.weight(.semibold))
                Spacer()
                Button("Done", action: onDone).keyboardShortcut(.defaultAction)
            }
            AppExplorerSettingsView(store: store, groupPath: groupPath, compact: true,
                configurationOverride: configurationOverride, windowManagerOnly: windowManagerOnly,
                onGroupPathChange: onGroupPathChange)
            Text("Changes save automatically · taps click while editing · swipe shortcuts resume when you finish")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(26).frame(width: 680)
            .environment(\.hotkeyDictionary, store.settings.resolvedHotkeyDictionary)
            .environment(\.hudActionLayers, store.settings.appExplorer?.holdLayers ?? [])
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
            Label(isNew ? "New Explorer group" : "Rename Explorer group", systemImage: "folder.fill").font(.headline)
            TextField("Group name", text: $name).textFieldStyle(.roundedBorder)
            Text("Name this group. Its contents can be assigned favorites or automatically filled recent apps.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button(isNew ? "Create group" : "Save") { onSave(trimmedName) }
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
    var onSave: (AppExplorerFavorite) -> Void
    var onCancel: () -> Void
    private var validURL: URL? {
        AppExplorerFavorite.webURL(address.trimmingCharacters(in: .whitespacesAndNewlines))
    }

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
            Text("URLs are included in settings export and cloud sync. Avoid private sign-in links or URLs containing secrets.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    guard let url = validURL else { return }
                    let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    onSave(AppExplorerFavorite(direction: direction, name: title.isEmpty ? (url.host ?? "Website") : title,
                        url: url.absoluteString))
                }.keyboardShortcut(.defaultAction).disabled(validURL == nil || name.count > 512)
            }
        }.textFieldStyle(.roundedBorder).padding(24).frame(width: 440)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}
