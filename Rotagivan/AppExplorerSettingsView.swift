import SwiftUI

struct HUDSettingsView: View {
    @ObservedObject var store: SettingsStore
    private let initialGroup: ExplorerReservedGroup?
    private let initialFocus: HUDWorkspaceFocus?
    private let defaultTaps: (() -> AnyView)?
    private let calibration: (() -> AnyView)?

    init(store: SettingsStore, initialGroup: ExplorerReservedGroup? = nil, initialFocus: HUDWorkspaceFocus? = nil,
         defaultTaps: (() -> AnyView)? = nil, calibration: (() -> AnyView)? = nil) {
        self.store = store
        self.initialGroup = initialGroup
        self.initialFocus = initialFocus
        self.defaultTaps = defaultTaps
        self.calibration = calibration
    }

    var body: some View {
        AppExplorerSettingsView(store: store, workspace: true,
            initialFocus: initialFocus ?? initialGroup.map { .builtInDefault($0) } ?? .hud,
            defaultTaps: defaultTaps, calibration: calibration)
    }
}

struct BuiltInHUDDefaultEditor: View {
    @ObservedObject var store: SettingsStore
    let group: ExplorerReservedGroup
    var chromeTabsProvider: @Sendable () -> [ChromeRecentTab] = { ChromeBookmarkTabs.snapshot() }
    @State private var selection: ExplorerSlot = .up
    @State private var editing: ExplorerSlot?
    @State private var restoring = false
    @State private var error: String?
    @State private var chromeTabs: [ChromeRecentTab] = []
    @State private var chromeTabsLoaded = false
    private var settings: AppExplorerSettings { store.settings.appExplorer ?? AppExplorerSettings() }
    private var layout: HUDDefaultLayout { settings.defaultLayout(for: group) }
    private var preview: AppExplorerSettings {
        var result = AppExplorerSettings()
        result.slotCount = layout.slotCount
        result.favorites = layout.favorites
        if !group.hasEditableDefaults && !group.showsChromeTabs {
            let slots = group == .recentApps ? ExplorerSlot.slots(layout.slotCount).sorted {
                ($0.angle + 180).truncatingRemainder(dividingBy: 360) < ($1.angle + 180).truncatingRemainder(dividingBy: 360)
            } : ExplorerSlot.slots(layout.slotCount)
            result.favorites = slots.enumerated().map { index, slot in
                AppExplorerFavorite(direction: slot, name: group == .chromeTabs ? "Chrome tab \(index + 1)" : group == .slackChannels ? "#channel \(index + 1)" : index == 0 ? "Active app" : "Recent app \(index)",
                    action: .appWindows)
            }
        }
        return result
    }
    private var chromePreviewEntries: [ExplorerEntry]? {
        if group == .recentAppsAndTabs {
            return chromeTabsLoaded ? AppExplorerController.previewRecentPlaceEntries(tabs: chromeTabs, count: layout.slotCount) : []
        }
        guard group == .chromeTabs else { return nil }
        let slots = ExplorerSlot.slots(layout.slotCount).sorted {
            ($0.angle + 180).truncatingRemainder(dividingBy: 360) < ($1.angle + 180).truncatingRemainder(dividingBy: 360)
        }
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome")
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        return chromeTabs.prefix(layout.slotCount).enumerated().map { offset, tab in
            var entry = ExplorerEntry(direction: slots[offset], bundleID: "com.google.Chrome",
                name: tab.title.isEmpty ? tab.url : tab.title, icon: icon, url: URL(string: tab.url))
            entry.chromeTab = tab
            entry.isActiveApp = offset == 0
            return entry
        }
    }
    private func loadChromeTabs() async {
        guard group.showsChromeTabs else { return }
        let provider = chromeTabsProvider
        let tabs = await Task.detached(priority: .userInitiated) { provider() }.value
        chromeTabs = ChromeTabRecency.shared.ranked(tabs)
        chromeTabsLoaded = true
    }
    private func save(_ layout: HUDDefaultLayout) {
        var next = settings
        if next.builtInDefaults == nil { next.builtInDefaults = [:] }
        next.builtInDefaults?[group.rawValue] = layout
        guard next.hasValidFavorites else { error = "Remove occupied tiles before reducing the number of slots."; return }
        store.settings.appExplorer = next; error = nil
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                RotaSelect("Tiles", selection: Binding(get: { layout.slotCount }, set: { count in
                    var next = layout; next.slotCount = count; save(next)
                }), values: Array(2...16)) { "\($0)" }
                Spacer()
                if group.showsChromeTabs {
                    Button("Refresh tabs") { Task { await loadChromeTabs() } }
                }
                Button("Restore original…") { restoring = true }.accessibilityIdentifier("builtin-hud-restore")
            }
            Text(group.hasEditableDefaults ? "Click a tile to edit the default. New \(group.title) HUDs use this layout; existing copies stay unchanged."
                : "Preview positions only. \(group == .chromeTabs ? "Open Chrome tabs" : group == .recentAppsAndTabs ? "Running apps and Chrome tabs" : "Running apps") fill these tiles on this Mac. Choose how many tiles new layers show.")
                .font(.callout).foregroundStyle(.secondary)
            ExplorerHUDSettingsPreview(settings: preview, theme: settings.resolvedTheme,
                dictionary: store.settings.resolvedHotkeyDictionary, groupPath: [], layerName: group.title,
                liveEntries: chromePreviewEntries,
                liveMessage: group == .chromeTabs ? (chromeTabsLoaded
                    ? (chromeTabs.isEmpty ? "No Chrome tabs available. Open Chrome and allow Rotagivan in Privacy & Security → Automation." : "Most recently used Chrome tabs · active tab on the left")
                    : "Loading Chrome tabs…")
                    : group == .recentAppsAndTabs ? (chromeTabsLoaded ? "Most recent app or Chrome tab on the left · the rest continue clockwise" : "Loading Chrome tabs…") : nil,
                selection: $selection, onBack: {}, onDrag: { _, _ in }, onDrop: { source, target in
                    guard group.hasEditableDefaults, let target else { return }
                    var next = preview
                    if next.swapFavorites(from: source, to: target) { save(HUDDefaultLayout(favorites: next.favorites, slotCount: layout.slotCount)) }
                }, editingTile: $editing, editor: group.hasEditableDefaults ? { slot in AnyView(tileEditor(slot)) } : nil,
                workspace: true)
                .frame(height: 410).accessibilityIdentifier("builtin-hud-preview")
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            Text("Add this layer from Add HUD or choose it under Built-in HUDs in a tile’s action picker.").font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
        .task { await loadChromeTabs() }
        .confirmationDialog("Restore the original \(group.title) default?", isPresented: $restoring) {
            Button("Restore original", role: .destructive) {
                var next = settings; next.builtInDefaults?[group.rawValue] = nil
                store.settings.appExplorer = next; error = nil; editing = nil
            }
        } message: { Text("Only this default is reset. Your existing HUD layers are kept.") }
    }
    private func tileEditor(_ slot: ExplorerSlot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(slot.title).font(.headline)
            BindingActionPicker(action: Binding(get: {
                layout.favorites.first { $0.direction == slot }.flatMap(BindingAction.from(favorite:)) ?? .tap(.none)
            }, set: { action in
                guard let tile = action.favorite(at: slot) else { return }
                var next = layout; next.favorites.removeAll { $0.direction == slot }; next.favorites.append(tile)
                save(next); editing = nil
            }))
            Button("Clear tile") {
                var next = layout; next.favorites.removeAll { $0.direction == slot }; save(next); editing = nil
            }
        }.padding(16).frame(width: 360)
    }
}

struct WindowManagerSettingsView: View {
    @ObservedObject var store: SettingsStore
    var workspace = false
    var showCanvas = true
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
            if showCanvas {
            AppExplorerSettingsView(store: store, workspace: workspace, configurationOverride: Binding(get: {
                explorer.windowEditor()
            }, set: { updated in
                var next = explorer
                guard next.saveWindowEditor(updated) else { error = "This HUD layer exceeds the nesting or tile limits."; return }
                store.settings.appExplorer = next; error = nil
            }), scopeTitle: "Window Manager", windowManagerOnly: true, windowApplet: true,
                windowOwnerPath: [])
            }
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
    @State private var workspaceDetails = false
    @State var workspaceFocus: HUDWorkspaceFocus = .hud
    @State var pendingGroupPath: [ExplorerSlot]?
    @State var showingWorkspaceOptions = false
    @State var restoringDefaultWindow = false
    @State private var pendingConversion: HUDLayerBuiltIn?
    @State private var confirmingConversion = false
    let defaultTaps: (() -> AnyView)?
    let calibration: (() -> AnyView)?
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
    private let workspace: Bool
    private let workspaceCanvasOnly: Bool
    private let workspaceMap: AppExplorerSettings?
    private let workspaceLayerID: UUID?
    private let onWorkspaceLayer: ((UUID?) -> Void)?
    private let onWorkspaceAddLayer: ((HUDLayerPosition) -> Void)?
    private var editingWindowManager: Bool { workspace && selectedBuiltIn == .windowManager }
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
    private var selectedBuiltIn: HUDLayerBuiltIn? {
        guard scopeTitle == nil, !windowManagerOnly else { return nil }
        return baseSettings.holdLayers?.first { $0.id == selectedLayerID }?.builtIn
    }
    private var generatedBuiltIn: HUDLayerBuiltIn? {
        guard let builtIn = selectedBuiltIn, builtIn != .actions, builtIn != .mediaControls else { return nil }
        return builtIn
    }
    private var isRecentGroup: Bool { settings.favorite(at: groupPath)?.isDynamicGroup == true }
    private var availableBookmarkSlots: [ExplorerSlot] {
        let occupied = Set(favorites.map(\.direction))
        return ExplorerSlot.slots(settings.count(at: groupPath)).filter { !occupied.contains($0) }
    }
    private var existingBookmarkURLs: Set<String> {
        Set(favorites.compactMap { favorite in
            favorite.url ?? (favorite.shortcut?.assignedAction?.kind == .openURL ? favorite.shortcut?.assignedAction?.url : nil)
        })
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
    private var swipeDirectionBinding: Binding<HUDSwipeDirection> {
        Binding(get: { baseSettings.resolvedSwipeDirection }, set: { direction in
            var next = baseSettings; next.swipeDirection = direction; saveBase(next)
        })
    }
    private var invertPickerBinding: Binding<Bool> {
        Binding(get: { baseSettings.resolvedInvertPickerDirection }, set: { enabled in
            var next = baseSettings; next.invertPickerDirection = enabled; saveBase(next)
        })
    }
    private var centerCursorBinding: Binding<Bool> {
        Binding(get: { baseSettings.resolvedCenterCursorOnAppSwitch }, set: { enabled in
            var next = baseSettings; next.centerCursorOnAppSwitch = enabled; saveBase(next)
        })
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

    private func addHUD(at position: HUDLayerPosition) {
        var next = baseSettings
        guard let id = next.assignEmptyHUD(at: position) else {
            groupError = "This position is no longer available. Your existing HUDs have been kept."
            return
        }
        if saveBase(next) { selectHUD(id) }
    }

    private var visualHUDPreview: some View {
        ExplorerHUDSettingsPreview(settings: settings, theme: store.settings.appExplorer?.resolvedTheme ?? settings.resolvedTheme,
            dictionary: store.settings.resolvedHotkeyDictionary, groupPath: groupPath,
            layerName: baseSettings.holdLayers?.first { $0.id == selectedLayerID }?.name ?? scopeTitle,
            // A standalone Window Manager editor shows only its own HUD, not the
            // surrounding layer map; the HUD workspace passes workspaceMap for that.
            rootSettings: workspaceMap ?? (windowManagerOnly && !workspace ? nil : baseSettings), selectedLayerID: workspaceMap == nil ? selectedLayerID : workspaceLayerID,
            onSelectLayer: onWorkspaceLayer ?? { id in selectedLayerID = id; groupPath = [] },
            onAddLayer: onWorkspaceAddLayer ?? { position in addHUD(at: position) },
            selection: $previewSelection, onBack: { if !groupPath.isEmpty { groupPath.removeLast() } },
            onDrag: { source, target in
                if previewDrag == nil { previewDrag = ExplorerSlotDrag(source: source, path: groupPath, settings: settings) }
            }, onDrop: { _, target in
                defer { previewDrag = nil }
                guard let drag = previewDrag, let target else { return }
                var next = settings
                if drag.apply(to: target, in: groupPath, settings: &next), save(next) { previewSelection = target }
            }, editingTile: $previewEditing, editor: generatedBuiltIn == nil ? { direction in tilePopover(direction) } : nil,
            editorPopover: !(workspace && !workspaceCanvasOnly), workspace: workspace)
            .padding(.top, workspace ? 0 : -20)
            .frame(maxWidth: .infinity)
    }

    private var visualHUDControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            visualHUDControlRow
            if workspace {
                HStack(spacing: 16) {
                    ScrollView(.horizontal, showsIndicators: true) {
                        HStack(spacing: 4) {
                            layerRailButton(nil, name: "Main HUD", symbol: "safari")
                            ForEach(baseSettings.holdLayers ?? []) { layer in
                                layerRailButton(layer.id, name: layer.name, symbol: layer.builtIn?.symbol ?? "square.3.layers.3d")
                            }
                        }.padding(.vertical, 4)
                    }.accessibilityIdentifier("hud-layer-rail")
                    if groupPath.isEmpty && !editingWindowManager { workspaceLocation.fixedSize() }
                }
            }
            if !workspace {
                Text("Click any surrounding HUD to bring it forward and edit it. Use Actions & hotkeys to add actions to the selected HUD.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var workspaceOptions: some View {
        RotaMenuButton("Options", systemImage: "slider.horizontal.3", help: "Theme and HUD options",
                       accessibilityTitle: "Theme and HUD options") {
            Picker("Theme", selection: themeBinding) {
                ForEach(ExplorerTheme.allCases, id: \.self) { Text($0.title).tag($0) }
            }
                Divider()
                Toggle("Invert picker direction", isOn: invertPickerBinding)
                Picker("Two-finger HUD navigation", selection: swipeDirectionBinding) {
                    ForEach(HUDSwipeDirection.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Divider()
                Toggle("Animate HUD feedback", isOn: animationBinding)
                Toggle("Put mouse in center of selected app", isOn: centerCursorBinding)
                Divider()
                Button("Layer settings…") { workspaceDetails = true }
                    .accessibilityIdentifier("hud-layer-settings")
                manageHUDCommands
        }
    }
    private var windowWorkspace: some View {
        AppExplorerSettingsView(store: store, workspace: true, workspaceCanvasOnly: true,
            workspaceMap: baseSettings, workspaceLayerID: selectedLayerID,
            onWorkspaceLayer: { id in selectedLayerID = id; groupPath = [] },
            onWorkspaceAddLayer: { position in addHUD(at: position) },
            configurationOverride: Binding(get: { baseSettings.windowEditor() }, set: { updated in
                var next = baseSettings
                guard next.saveWindowEditor(updated), next.hasValidFavorites else {
                    groupError = "This Window Manager layout exceeds the nesting or tile limits."; return
                }
                _ = saveBase(next)
            }), scopeTitle: "Window Manager", windowManagerOnly: true, windowApplet: true,
            windowOwnerPath: [])
    }
    private var workspaceLocation: some View {
        HStack(spacing: 6) {
            if workspaceCanvasOnly || !groupPath.isEmpty {
                Button(baseSettings.holdLayers?.first { $0.id == selectedLayerID }?.name ?? scopeTitle ?? "Main HUD") { groupPath = [] }
                    .buttonStyle(.rotaLink).lineLimit(1)
            }
            ForEach(groupPath.indices, id: \.self) { index in
                Image(systemName: "chevron.right").font(.caption2)
                Button(settings.favorite(at: Array(groupPath.prefix(index + 1)))?.name ?? "HUD layer") {
                    groupPath = Array(groupPath.prefix(index + 1))
                }.buttonStyle(.rotaLink).lineLimit(1)
            }
            if workspaceCanvasOnly || !groupPath.isEmpty { Spacer(minLength: 4) }
            if generatedBuiltIn == nil {
                RotaMenuButton("\(settings.count(at: groupPath)) slots", kind: .field) {
                    Picker("Slots", selection: Binding(get: { settings.count(at: groupPath) }, set: { count in
                        var next = settings
                        guard next.resize(to: count, at: groupPath) else {
                            groupError = "Remove some tiles before choosing fewer slots. Your existing tiles have been kept."; return
                        }
                        _ = save(next)
                    })) { ForEach(Array(2...16), id: \.self) { Text("\($0) slots").tag($0) } }
                    if !groupPath.isEmpty, settings.favorite(at: groupPath)?.isPureGroup == true {
                        Picker("Contents", selection: Binding(get: { settings.favorite(at: groupPath)?.groupMode ?? .favorites }, set: { mode in
                            guard let direction = groupPath.last, var group = settings.favorite(at: groupPath) else { return }
                            group.groupMode = mode
                            edit { $0.setFavorite(group, at: direction, in: Array(groupPath.dropLast())) }
                        })) {
                            Text("Assigned favorites").tag(AppExplorerMode.favorites)
                            Text("Recent apps").tag(AppExplorerMode.recent)
                        }
                        Button("Rename…") { editingGroupPath = groupPath }
                    }
                }
                .accessibilityIdentifier("hud-workspace-slots")
            }
        }.font(.caption).accessibilityIdentifier("hud-workspace-location")
    }
    private func layerRailButton(_ id: UUID?, name: String, symbol: String) -> some View {
        Button { selectedLayerID = id; groupPath = [] } label: {
            Text(name).font(.system(size: 12, weight: selectedLayerID == id ? .semibold : .regular))
                .lineLimit(1).fixedSize().padding(.horizontal, 12).padding(.vertical, 7)
                .foregroundStyle(selectedLayerID == id ? Color.primary : Color.secondary)
                .background(selectedLayerID == id ? Color.accentColor.opacity(0.14) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 7))
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain)
            .accessibilityIdentifier("hud-layer-button-" + (id?.uuidString ?? "main"))
            .accessibilityValue(selectedLayerID == id ? "Selected" : "Not selected")
    }
    private var visualHUDControlRow: some View {
            HStack {
                if workspaceCanvasOnly {
                    hudLayerPicker(showsTitle: false).frame(width: 160)
                } else if !workspace { hudLayerPicker(showsTitle: true).frame(maxWidth: 260) }
                Button("Actions & hotkeys…") {
                    if !groupPath.isEmpty { openGroupHotkeys() }
                    else if let layer = baseSettings.holdLayers?.first(where: { $0.id == selectedLayerID }) {
                        creatingLayer = false; editingLayer = layer
                    } else { editingDefaultLayer = true }
                }
                .accessibilityIdentifier("hud-visual-actions")
                .help("Actions and hotkeys for this HUD")
                Spacer(minLength: 8)
                RotaMenuButton("Add HUD", systemImage: "plus") {
                    Button("Custom HUD…") { creatingLayer = true; editingLayer = .empty() }
                    if scopeTitle == nil && !windowManagerOnly {
                        Menu("Templates") {
                            ForEach(HUDLayerTemplate.allCases) { template in
                                Menu(template.title) {
                                    ForEach(HUDLayerPosition.allCases.filter { layerAt($0) == nil }) { position in
                                        Button(position.title) {
                                            var next = baseSettings
                                            guard let id = next.assignTemplate(template, at: position) else { return }
                                            if saveBase(next) { selectedLayerID = id; groupPath = [] }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    if scopeTitle == nil && !windowManagerOnly {
                        ForEach(HUDLayerBuiltIn.allCases) { builtIn in
                            Menu(builtIn.title) {
                                ForEach(HUDLayerPosition.allCases.filter { layerAt($0) == nil }) { position in
                                    Button(position.title) {
                                        var next = baseSettings
                                        guard let id = next.assignBuiltIn(builtIn, at: position) else { return }
                                        if saveBase(next) { selectedLayerID = id; groupPath = [] }
                                    }
                                }
                            }
                        }
                    }
                }
                .disabled(baseSettings.resolvedHUDPositions.count >= HUDLayerPosition.allCases.count ||
                    (scopeTitle != nil && baseSettings.holdLayers == nil))
                .accessibilityIdentifier("hud-visual-add")
                if workspace && !workspaceCanvasOnly {
                    workspaceOptions
                } else {
                    RotaMenuButton("Manage", systemImage: "ellipsis.circle") { manageHUDCommands }
                }
            }
    }
    @ViewBuilder private var manageHUDCommands: some View {
        Button("Import bookmarks…") { importingBookmarks = true }
            .disabled(generatedBuiltIn != nil || isRecentGroup || availableBookmarkSlots.isEmpty)
        if let layer = baseSettings.holdLayers?.first(where: { $0.id == selectedLayerID }) {
            Button("Rename / edit HUD…") { creatingLayer = false; editingLayer = layer }
            Menu("Position") {
                ForEach(HUDLayerPosition.allCases) { position in
                    Button(position.title) { placeHUDLayer(layer.id, at: position) }
                }
            }
            Button("Remove HUD…", role: .destructive) { removingLayer = true }
        }
    }
    private var layerOptions: [RotaOption<UUID?>] {
        [RotaOption(scopeTitle ?? "Main HUD", value: nil)] +
            (baseSettings.holdLayers ?? []).map { RotaOption($0.name, value: Optional($0.id)) }
    }
    private func hudLayerPicker(showsTitle: Bool) -> some View {
        RotaSelect(workspaceCanvasOnly ? "Window layout" : "Editing HUD", selection: $selectedLayerID,
                   options: layerOptions, showsTitle: showsTitle, fill: true)
            .accessibilityIdentifier("hud-layer-picker")
    }

    var compact = false
    var onGroupPathChange: (([ExplorerSlot]) -> Void)? = nil

    init(store: SettingsStore, groupPath: [ExplorerSlot] = [], compact: Bool = false, initialLayerID: UUID? = nil, workspace: Bool = false,
         workspaceCanvasOnly: Bool = false,
         workspaceMap: AppExplorerSettings? = nil, workspaceLayerID: UUID? = nil,
         onWorkspaceLayer: ((UUID?) -> Void)? = nil,
         onWorkspaceAddLayer: ((HUDLayerPosition) -> Void)? = nil,
         configurationOverride: Binding<AppExplorerSettings>? = nil, scopeTitle: String? = nil, windowManagerOnly: Bool = false, windowApplet: Bool = false,
         transferRoot: (() -> AppExplorerSettings)? = nil, transferSave: ((AppExplorerSettings) -> Bool)? = nil,
         transferPrefix: [ExplorerTilePathStep] = [], windowOwnerPath: [ExplorerTilePathStep]? = nil,
         onGroupPathChange: (([ExplorerSlot]) -> Void)? = nil,
         initialFocus: HUDWorkspaceFocus = .hud, defaultTaps: (() -> AnyView)? = nil, calibration: (() -> AnyView)? = nil) {
        self.store = store
        _workspaceFocus = State(initialValue: initialFocus)
        self.defaultTaps = defaultTaps
        self.calibration = calibration
        _groupPath = State(initialValue: groupPath)
        _selectedLayerID = State(initialValue: initialLayerID)
        self.compact = compact
        self.workspace = workspace
        self.workspaceCanvasOnly = workspaceCanvasOnly
        self.workspaceMap = workspaceMap
        self.workspaceLayerID = workspaceLayerID
        self.onWorkspaceLayer = onWorkspaceLayer
        self.onWorkspaceAddLayer = onWorkspaceAddLayer
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
            if workspace && !workspaceCanvasOnly {
                workspaceLayout
            } else if workspace {
                visualHUDControlRow
                if !editingWindowManager { workspaceLocation }
                if editingWindowManager { windowWorkspace }
                else { visualHUDPreview.frame(maxWidth: .infinity, maxHeight: .infinity) }
            } else {
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
                    RotaSelect("Theme", selection: themeBinding, values: ExplorerTheme.allCases, fill: true) { $0.title }
                        .frame(width: 230)
                    RotaMenuButton("Options", systemImage: "slider.horizontal.3") {
                        Toggle("Invert picker direction", isOn: invertPickerBinding)
                            .help("Reverse one-finger tile selection, including voice, window, and deep choices.")
                        Picker("Two-finger HUD navigation", selection: swipeDirectionBinding) {
                            ForEach(HUDSwipeDirection.allCases, id: \.self) { direction in
                                Text(direction.title).tag(direction)
                            }
                        }
                        .help("Default navigation in every direction: inverted drags down to the HUD above; regular swipes down to the HUD below. Explicit gesture assignments keep their assigned actions.")
                        Divider()
                        Toggle("Animate HUD feedback", isOn: animationBinding)
                        Toggle("Put mouse in center of selected app", isOn: centerCursorBinding)
                    }
                }
            }
            if compact {
                HStack {
                    if scopeTitle == nil {
                        RotaMenuButton("Explorer appearance", systemImage: "paintpalette", kind: .icon) {
                            Picker("Theme", selection: themeBinding) {
                                ForEach(ExplorerTheme.allCases, id: \.self) { Text($0.title).tag($0) }
                            }
                            Toggle("Animate HUD feedback", isOn: animationBinding)
                            Toggle("Put mouse in center of selected app", isOn: centerCursorBinding)
                        }
                    }
                    RotaSelect("HUD layer", selection: $selectedLayerID, options: [RotaOption("Default", value: nil as UUID?)] +
                        (baseSettings.holdLayers ?? []).map { RotaOption($0.name, value: Optional($0.id)) })
                    Button("Add HUD layer") {
                        creatingLayer = true
                        editingLayer = .empty()
                    }.disabled(baseSettings.resolvedHUDPositions.count >= HUDLayerPosition.allCases.count ||
                        (scopeTitle != nil && baseSettings.holdLayers == nil))
                    Button {
                        importingBookmarks = true
                    } label: {
                        Label("Import bookmarks", systemImage: "book.closed")
                    }
                    .disabled(generatedBuiltIn != nil || isRecentGroup || availableBookmarkSlots.isEmpty)
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
                visualHUDControls
            }
            if scopeTitle == nil && compact {
                Text("Assign keyboard shortcuts or trackpad gestures to this layer’s actions.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if windowManagerOnly {
                Text("Slot direction and window position are independent. Use ••• → Window management → Resize window to assign any position and size.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let builtIn = generatedBuiltIn {
                if !compact && !(workspace && builtIn == .windowManager) { visualHUDPreview }
                RotaCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Label(builtIn.title, systemImage: builtIn.symbol).font(.headline)
                        Text("This position opens the built-in HUD directly. Swipe to another position to leave it.")
                            .font(.callout).foregroundStyle(.secondary)
                        if builtIn == .windowManager {
                            WindowManagerSettingsView(store: store, workspace: workspace)
                        } else if builtIn == .recentApps {
                            Text("The active app is outlined on the left. Other recent apps start at top-left and continue clockwise.")
                        } else if builtIn == .chromeTabs {
                            Text("Open Chrome tabs fill this HUD. Swipe to a tab and lift to focus it. Allow Google Chrome under Privacy & Security → Automation if requested.")
                        } else if builtIn == .recentAppsAndTabs || builtIn == .slackChannels {
                            Text(builtInDescription(builtIn))
                        } else {
                            Text("Volume, mute, previous/next track, and play/pause. Single tap plays or pauses.")
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
            RotaSelect(settings.favorite(at: groupPath)?.hasPrimaryDestination == true ? "Slots in this deep swipe" : "Slots in this HUD layer",
                selection: Binding(get: { settings.count(at: groupPath) }, set: { count in
                var next = settings
                guard next.resize(to: count, at: groupPath) else {
                    groupError = "Remove some tiles before choosing fewer slots. Your existing tiles have been kept."; return
                }
                _ = save(next)
            }), values: Array(2...16)) { "\($0) slots" }
            HStack(spacing: 5) {
                Button(baseSettings.holdLayers?.first { $0.id == selectedLayerID }?.name ?? "Default") { groupPath = [] }
                    .buttonStyle(.rotaLink)
                ForEach(groupPath.indices, id: \.self) { index in
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    Button(settings.favorite(at: Array(groupPath.prefix(index + 1)))?.name ?? "HUD layer") {
                        groupPath = Array(groupPath.prefix(index + 1))
                    }.buttonStyle(.rotaLink).lineLimit(1)
                }
                Spacer(minLength: 4)
                if !groupPath.isEmpty {
                    Button("Edit hotkeys…") { openGroupHotkeys() }
                    Button("Rename…") { editingGroupPath = groupPath }
                }
            }.font(.subheadline.weight(.medium))
            if !groupPath.isEmpty, settings.favorite(at: groupPath)?.isPureGroup == true {
                RotaSegmented("HUD layer contents", selection: Binding(get: {
                    settings.favorite(at: groupPath)?.groupMode ?? .favorites
                }, set: { mode in
                    guard let direction = groupPath.last, var group = settings.favorite(at: groupPath) else { return }
                    group.groupMode = mode
                    edit { $0.setFavorite(group, at: direction, in: Array(groupPath.dropLast())) }
                }), options: [
                    RotaOption("Assigned favorites", value: AppExplorerMode.favorites),
                    RotaOption("Recent apps", value: AppExplorerMode.recent),
                    RotaOption("Chrome tabs", value: AppExplorerMode.chromeTabs),
                    RotaOption("Apps & tabs", value: AppExplorerMode.recentAppsAndTabs)])
            }
            if !compact {
                visualHUDPreview
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
                ? "The active app is outlined on the left. Other recent apps start at top-left and continue clockwise. Any assigned favorites are kept if you switch back. Tap the center in the HUD to go back."
                : "Click a tile to edit it right there. Drag to rearrange, or choose Send to HUD layer to move it across layers. Preview clicks never launch apps or run actions.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            }
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
                        var action = BindingAction.openURL(bookmark.url.absoluteString)
                        action.targetBrowserBundleID = bookmark.source == .chrome ? "com.google.Chrome" : "com.apple.Safari"
                        guard var favorite = action.favorite(at: slot) else { return false }
                        favorite.name = bookmark.title
                        guard next.setFavorite(favorite, at: slot, in: groupPath) else { return false }
                    }
                    guard next.hasValidFavorites, save(next) else { return false }
                    importingBookmarks = false
                    groupError = nil
                    return true
                }, onCancel: { importingBookmarks = false })
        }
        .sheet(isPresented: $workspaceDetails) {
            VStack(alignment: .trailing, spacing: 12) {
                ScrollView {
                    if editingWindowManager { WindowManagerSettingsView(store: store, showCanvas: false) }
                    else {
                        AppExplorerSettingsView(store: store, groupPath: groupPath, compact: true,
                            initialLayerID: selectedLayerID, configurationOverride: configurationOverride,
                            scopeTitle: scopeTitle, windowManagerOnly: windowManagerOnly, windowApplet: windowApplet,
                            transferRoot: transferRoot, transferSave: transferSave, transferPrefix: transferPrefix,
                            windowOwnerPath: windowOwnerPath)
                    }
                }
                Button("Done") { workspaceDetails = false }.keyboardShortcut(.cancelAction)
            }.padding(24).frame(width: 660, height: 640)
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
        .onChange(of: selectedLayerID) { _, _ in groupPath = pendingGroupPath ?? []; pendingGroupPath = nil; groupError = nil; slotDrag = nil; dropTarget = nil; previewDrag = nil; previewEditing = nil }
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

    private func tilePopover(_ direction: ExplorerSlot, inline: Bool = false) -> AnyView {
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
                .help(inline ? "Deselect tile" : "Close tile editor")
                .accessibilityIdentifier("hud-inspector-deselect")
            }
            .padding(inline ? 14 : 16)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                TileActionPicker(current: favorite.flatMap(BindingAction.from(favorite:)), name: favorite?.name, icon: {
                    if let favorite { tileAssignmentIcon(favorite) }
                    else { Image(systemName: "plus").foregroundStyle(.teal) }
                }, onSelect: { selected in
                    guard let replacement = selected.favorite(at: direction) else { return }
                    edit { $0.setFavorite(preservingHotkey(replacement, at: groupPath + [direction]), at: direction, in: groupPath) }
                }, onSelectBuiltIn: { group in
                    guard groupPath.count < AppExplorerSettings.maximumGroupDepth || (group == .windowManager && !windowManagerOnly) else { return }
                    let tile = preservingHotkey(baseSettings.builtInTile(group, at: direction, insideWindowManager: windowManagerOnly),
                        at: groupPath + [direction])
                    edit { $0.setFavorite(tile, at: direction, in: groupPath) }
                    previewEditing = nil
                })
                if let selected = favorite.flatMap(BindingAction.from(favorite:)) {
                    Text(selected.description).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let favorite {
                    Button("Assign tap or swipe to this action…") {
                        guard let assigned = tileBindingAction(favorite, at: direction) else { return }
                        editingTileBinding = ActionBinding(trigger: BindingTrigger(), action: assigned)
                    }
                    .disabled(tileBindingAction(favorite, at: direction) == nil)
                }

                if let favorite, favorite.bundleID != nil {
                    Toggle("Show this app’s windows", isOn: Binding(get: { favorite.showsWindows == true }, set: { enabled in
                        var updated = favorite; updated.showsWindows = enabled
                        edit { $0.setFavorite(updated, at: direction, in: groupPath) }
                    }))
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
                            RotaMenuButton("Move within this layer", systemImage: "arrow.left.arrow.right", kind: .field) {
                                ForEach(ExplorerSlot.slots(settings.count(at: groupPath)).filter { $0 != direction }, id: \.self) { target in
                                    Button(target.title) {
                                        edit { $0.swapFavorites(from: direction, to: target, in: groupPath) }
                                        previewEditing = nil
                                    }
                                }
                            }
                            if !inline {
                                Spacer()
                                Button("Remove tile", role: .destructive) {
                                    edit { $0.setFavorite(nil, at: direction, in: groupPath) }
                                    previewEditing = nil
                                }
                            }
                        }
                        if inline {
                            Button("Remove tile", role: .destructive) {
                                edit { $0.setFavorite(nil, at: direction, in: groupPath) }
                                previewEditing = nil
                            }.accessibilityIdentifier("hud-inspector-remove-tile")
                        }
                    }
                    .font(.caption)
                    .controlSize(.small)
                }
            }
            .padding(inline ? 14 : 16)
        }
        .frame(width: inline ? nil : 560, alignment: .leading))
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
                RotaMenuButton("Edit \(direction.title) slot", systemImage: "ellipsis", kind: .icon) {
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
                }
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
                }.font(.caption2).buttonStyle(.rotaLink)
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
        } label: { Label("Actions", systemImage: "keyboard") }
        Menu {
            Button("Choose app…", systemImage: "app") { editingApplicationPath = groupPath + [direction] }
            Button(favorite?.url != nil ? "Edit URL…" : "Open URL…", systemImage: "globe") { editingURLPath = groupPath + [direction] }
            Button("Import Chrome or Safari bookmarks…", systemImage: "book.closed") {
                importingBookmarks = true
            }
            .disabled(generatedBuiltIn != nil || isRecentGroup || availableBookmarkSlots.isEmpty)
            if let favorite, favorite.bundleID != nil {
                Divider()
                Toggle("Show this app’s windows", isOn: Binding(get: { favorite.showsWindows == true }, set: { enabled in
                    var updated = favorite; updated.showsWindows = enabled
                    edit { $0.setFavorite(updated, at: direction, in: groupPath) }
                }))
            }
        } label: { Label("App launches", systemImage: "app") }
        // Built-in HUDs are assigned in one place only: the tile's action picker.
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
        Menu("Media actions") {
            ForEach(ExplorerMediaAction.allCases, id: \.self) { media in mediaActionButton(media, at: direction) }
        }
        Button("Media controls", systemImage: "speaker.wave.2.fill") {
            edit { $0.setFavorite(preservingHotkey(AppExplorerFavorite(direction: direction, name: "Media Controls", action: .mediaControls),
                at: groupPath + [direction]), at: direction, in: groupPath) }
        }
    }

    private func mediaActionButton(_ media: ExplorerMediaAction, at direction: ExplorerSlot, closeEditor: Bool = false) -> some View {
        Button(media.title, systemImage: media.symbol) {
            guard let favorite = BindingAction.media(media).favorite(at: direction) else { return }
            edit { $0.setFavorite(preservingHotkey(favorite, at: groupPath + [direction]), at: direction, in: groupPath) }
            if closeEditor { previewEditing = nil }
        }
    }

    private func windowActionButton(_ action: AppExplorerAction, at direction: ExplorerSlot, closeEditor: Bool = false) -> some View {
        Button(action.title, systemImage: action.symbol) {
            edit { $0.setFavorite(preservingHotkey(AppExplorerFavorite(direction: direction, name: action.title, action: action),
                at: groupPath + [direction]), at: direction, in: groupPath) }
            if closeEditor { previewEditing = nil }
        }.help(action.description)
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
            Text(rank == 1 ? "Active app" : "Recent app \(rank - 1)").font(.caption)
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
            if next.holdLayers?[index].builtIn == .mediaControls || next.holdLayers?[index].builtIn == .actions {
                next.holdLayers?[index].builtIn = nil
            }
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
enum HUDWorkspaceFocus: Hashable {
    case hud, defaultTaps, swipes, calibration, builtInDefault(ExplorerReservedGroup)
}

/// HUD workspace: a HUD list, the live HUD canvas, and an inspector for the
/// selected tile or HUD. Edits apply directly instead of through popovers.
extension AppExplorerSettingsView {
    static let navigatorWidth: CGFloat = 196
    static let inspectorWidth: CGFloat = 284

    var workspaceLayout: some View {
        HStack(spacing: 0) {
            hudNavigator.frame(width: Self.navigatorWidth)
            Divider()
            switch workspaceFocus {
            case .hud:
                workspaceCanvas.frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                ScrollView { workspaceInspector.frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(width: Self.inspectorWidth)
                    .background(.thinMaterial)
                    .accessibilityIdentifier("hud-inspector")
            case .defaultTaps:
                ScrollView { defaultTaps?().padding(20) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.thinMaterial)
            case .swipes:
                ScrollView { swipesPane.padding(20) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.thinMaterial)
            case .calibration:
                ScrollView { calibration?().padding(20) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.thinMaterial)
                    .accessibilityIdentifier("tap-calibration")
            case .builtInDefault(let group):
                builtInDefaultPane(group)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(.thinMaterial)
            }
        }
    }

    func selectHUD(_ id: UUID?, path: [ExplorerSlot] = []) {
        workspaceFocus = .hud
        previewEditing = nil
        if id == selectedLayerID { groupPath = path } else { pendingGroupPath = path; selectedLayerID = id }
    }

    private var freeHUDPosition: HUDLayerPosition? {
        let used = Set(baseSettings.resolvedHUDPositions.values)
        return HUDLayerPosition.legacyOrder.first { !used.contains($0) }
    }

    private var selectedHoldLayer: ExplorerHoldLayer? {
        baseSettings.holdLayers?.first { $0.id == selectedLayerID }
    }

    // MARK: Navigator

    private var hudNavigator: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    let showsSwipes = scopeTitle == nil && !windowManagerOnly
                    let tapsSection = defaultTaps != nil || calibration != nil || showsSwipes
                    if tapsSection {
                        navigatorHeading("Taps & swipes")
                        if defaultTaps != nil {
                            navigatorRow("Default taps", symbol: "hand.tap", selected: workspaceFocus == .defaultTaps,
                                id: "hud-default-taps") { workspaceFocus = .defaultTaps; previewEditing = nil }
                                .help("Tap and swipe actions used whenever no HUD is open")
                        }
                        if showsSwipes {
                            navigatorRow("Swipes", symbol: "hand.draw", selected: workspaceFocus == .swipes,
                                id: "hud-swipes") { workspaceFocus = .swipes; previewEditing = nil }
                                .help("Which way one-finger tile selection and two-finger HUD navigation go")
                        }
                        if calibration != nil {
                            navigatorRow("Calibration", symbol: "waveform.path.ecg", selected: workspaceFocus == .calibration,
                                id: "hud-calibration") { workspaceFocus = .calibration; previewEditing = nil }
                                .help("Teach Rotagivan your double-tap speed and tune tap recognition")
                        }
                    }
                    navigatorHeading("HUDs").padding(.top, tapsSection ? 10 : 0)
                    hudRows(nil, name: scopeTitle ?? "Main HUD", symbol: "safari", position: nil)
                    ForEach(baseSettings.holdLayers ?? []) { layer in
                        hudRows(layer.id, name: layer.name, symbol: layer.builtIn?.symbol ?? "square.3.layers.3d",
                            position: baseSettings.resolvedHUDPositions[layer.id])
                    }
                    if scopeTitle == nil && !windowManagerOnly {
                        navigatorHeading("Built-in defaults").padding(.top, 10)
                        ForEach(ExplorerReservedGroup.allCases) { group in
                            navigatorRow(group.title, symbol: group.symbol, selected: workspaceFocus == .builtInDefault(group),
                                id: "hud-builtin-default-" + group.rawValue) {
                                workspaceFocus = .builtInDefault(group); previewEditing = nil
                            }.help(group.summary)
                        }
                    }
                }.padding(10)
            }
            Divider()
            HStack {
                newHUDMenu
                Spacer()
            }.padding(.horizontal, 10).padding(.vertical, 8)
        }
        .background(.thinMaterial)
        .accessibilityIdentifier("hud-navigator")
    }

    private func navigatorHeading(_ title: String) -> some View {
        Text(title.uppercased()).font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(1.2)
            .foregroundStyle(.secondary).padding(.horizontal, 8).padding(.bottom, 4)
    }

    @ViewBuilder private func hudRows(_ id: UUID?, name: String, symbol: String, position: HUDLayerPosition?) -> some View {
        let selected = workspaceFocus == .hud && selectedLayerID == id
        navigatorRow(name, symbol: symbol, selected: selected && groupPath.isEmpty,
            id: "hud-layer-button-" + (id?.uuidString ?? "main"), trailing: position?.symbol,
            accessibilitySelected: selected) { selectHUD(id) }
            .help(position.map { "\(name) · \($0.title) of Main HUD" } ?? name)
        let builtIn = baseSettings.holdLayers?.first { $0.id == id }?.builtIn
        if builtIn == nil || builtIn == .actions || builtIn == .mediaControls {
            let projected = baseSettings.projected(layerID: id)
            ForEach(nestedHUDPaths(in: projected, under: []), id: \.self) { path in
                let group = projected.favorite(at: path)
                navigatorRow(group?.name ?? "HUD", symbol: group?.isDynamicGroup == true ? "clock.arrow.circlepath" : "folder",
                    selected: selected && groupPath == path,
                    id: "hud-nested-" + (id?.uuidString ?? "main") + "-" + path.map(\.rawValue).joined(separator: "-"),
                    depth: path.count) { selectHUD(id, path: path) }
            }
        }
    }

    private func nestedHUDPaths(in settings: AppExplorerSettings, under path: [ExplorerSlot]) -> [[ExplorerSlot]] {
        let order = ExplorerSlot.slots(16)
        return (settings.favorites(at: path) ?? [])
            .filter { $0.isGroup && !$0.isWindowManager }
            .sorted { (order.firstIndex(of: $0.direction) ?? 0) < (order.firstIndex(of: $1.direction) ?? 0) }
            .flatMap { group -> [[ExplorerSlot]] in
                let child = path + [group.direction]
                return [child] + nestedHUDPaths(in: settings, under: child)
            }
    }

    private func navigatorRow(_ title: String, symbol: String, selected: Bool, id: String, depth: Int = 0,
                              trailing: String? = nil, accessibilitySelected: Bool? = nil,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol).frame(width: 16)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                Text(title).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 2)
                if let trailing { Image(systemName: trailing).font(.caption2).foregroundStyle(.tertiary) }
            }
            .font(.system(size: 12, weight: selected ? .semibold : .regular))
            .padding(.leading, 8 + CGFloat(depth) * 14).padding(.trailing, 8).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.accentColor.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
        .accessibilityValue((accessibilitySelected ?? selected) ? "Selected" : "Not selected")
    }

    private var newHUDMenu: some View {
        RotaMenuButton("New HUD", systemImage: "plus",
                       help: freeHUDPosition == nil ? "All eight positions around Main HUD are in use" : "Add a HUD next to Main HUD") {
            Button("Blank HUD", systemImage: "square.dashed") {
                if let position = freeHUDPosition { addHUD(at: position) }
            }
            Menu("From template") {
                ForEach(HUDLayerTemplate.allCases) { template in
                    Button(template.title) {
                        guard let position = freeHUDPosition else { return }
                        var next = baseSettings
                        guard let id = next.assignTemplate(template, at: position) else { return }
                        if saveBase(next) { selectHUD(id) }
                    }
                }
            }
            Menu("Built-in") {
                ForEach(HUDLayerBuiltIn.allCases) { builtIn in
                    Button(builtIn.title, systemImage: builtIn.symbol) {
                        guard let position = freeHUDPosition else { return }
                        var next = baseSettings
                        guard let id = next.assignBuiltIn(builtIn, at: position) else { return }
                        if saveBase(next) { selectHUD(id) }
                    }
                }
            }
        }
        .disabled(freeHUDPosition == nil || scopeTitle != nil)
        .accessibilityIdentifier("hud-visual-add")
    }

    // MARK: Canvas

    private var workspaceCanvas: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Button(selectedHoldLayer?.name ?? scopeTitle ?? "Main HUD") { groupPath = []; previewEditing = nil }
                    .buttonStyle(.rotaLink).lineLimit(1).disabled(groupPath.isEmpty)
                ForEach(groupPath.indices, id: \.self) { index in
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    Button(settings.favorite(at: Array(groupPath.prefix(index + 1)))?.name ?? "HUD") {
                        groupPath = Array(groupPath.prefix(index + 1)); previewEditing = nil
                    }.buttonStyle(.rotaLink).lineLimit(1).disabled(index == groupPath.count - 1)
                }
                Spacer(minLength: 8)
                Button { showingWorkspaceOptions.toggle() } label: { Label("HUD options", systemImage: "gearshape") }
                    .buttonStyle(.rotaIcon)
                    .help("HUD appearance and navigation")
                    .accessibilityLabel("HUD appearance and navigation")
                    .accessibilityIdentifier("hud-workspace-options")
                    .popover(isPresented: $showingWorkspaceOptions, arrowEdge: .bottom) { workspaceOptionsForm }
            }
            .font(.callout)
            .padding(.horizontal, 14).padding(.top, 10)
            .accessibilityIdentifier("hud-workspace-location")
            if editingWindowManager { windowWorkspace.padding(.horizontal, 10) }
            else { visualHUDPreview.frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
    }

    private var workspaceOptionsForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("HUD options").font(.headline)
            RotaSelect("Theme", selection: themeBinding, values: ExplorerTheme.allCases) { $0.title }
            Toggle("Animate HUD feedback", isOn: animationBinding)
            Toggle("Put mouse in center of selected app", isOn: centerCursorBinding)
            Text("Swipe directions live under Taps & swipes › Swipes.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(16).frame(width: 340)
        .accessibilityIdentifier("hud-workspace-options-form")
    }

    /// Taps & swipes › Swipes: the one place that decides which way swipes go.
    private var swipesPane: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Swipes").font(.system(size: 24, weight: .semibold))
                Text("Which way the HUD responds to a swipe. Changes apply to every HUD at once.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            RotaCard("One-finger tile selection", systemImage: "hand.point.up.left") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Invert selection direction", isOn: invertPickerBinding)
                        .toggleStyle(.rotaSwitch)
                        .accessibilityIdentifier("hud-invert-picker")
                    Text(baseSettings.resolvedInvertPickerDirection
                        ? "Inverted: swiping up selects the tile at the bottom, as if pulling the wheel toward you. Turn this off to select the tile in the direction you swipe."
                        : "Swiping toward a tile selects it. Turn this on to select the opposite tile, as if pulling the wheel toward you.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text("Also applies to voice choices, window placement and deep swipe options.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            RotaCard("Two-finger HUD navigation", systemImage: "hand.draw") {
                VStack(alignment: .leading, spacing: 8) {
                    RotaSelect("Direction", selection: swipeDirectionBinding, values: HUDSwipeDirection.allCases) { $0.title }
                        .accessibilityIdentifier("hud-swipe-direction")
                    Text(baseSettings.resolvedSwipeDirection == .inverted
                        ? "Inverted (default): dragging two fingers down moves to the HUD above, like scrolling content. Choose Regular to move to the HUD below instead."
                        : "Regular: swiping two fingers down moves to the HUD below. Choose Inverted to drag the map like content.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text("Gestures you assigned explicitly in Default taps keep their own actions.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
        .accessibilityIdentifier("hud-swipes")
    }

    // MARK: Inspector

    @ViewBuilder private var workspaceInspector: some View {
        if let direction = previewEditing, generatedBuiltIn == nil, !editingWindowManager, !isRecentGroup {
            tilePopover(direction, inline: true)
        } else {
            hudInspector
        }
    }

    private var inspectorKind: String {
        if !groupPath.isEmpty {
            let parent = groupPath.count == 1 ? (selectedHoldLayer?.name ?? scopeTitle ?? "Main HUD")
                : (settings.favorite(at: Array(groupPath.dropLast()))?.name ?? "HUD")
            return "Nested HUD · opened from \(parent)"
        }
        if let layer = selectedHoldLayer {
            let position = baseSettings.resolvedHUDPositions[layer.id].map { " · \($0.title)" } ?? ""
            return (layer.builtIn.map { "Built-in \($0.title)" } ?? "HUD") + position
        }
        return scopeTitle == nil ? "Center of the HUD map" : "Layers for \(scopeTitle!)"
    }

    private var hudInspector: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: groupPath.isEmpty ? (selectedHoldLayer?.builtIn?.symbol ?? (selectedHoldLayer == nil ? "safari" : "square.3.layers.3d")) : "folder")
                    .font(.title2).foregroundStyle(.teal).frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(groupPath.isEmpty ? (selectedHoldLayer?.name ?? scopeTitle ?? "Main HUD") : (settings.favorite(at: groupPath)?.name ?? "HUD"))
                        .font(.headline).lineLimit(2)
                    Text(inspectorKind).font(.caption).foregroundStyle(.secondary)
                }
            }
            if groupPath.isEmpty, let layer = selectedHoldLayer {
                inspectorField("Name") {
                    HUDInspectorNameField(name: layer.name) { name in
                        var next = baseSettings
                        guard let index = next.holdLayers?.firstIndex(where: { $0.id == layer.id }) else { return }
                        next.holdLayers![index].name = name
                        saveBase(next)
                    }.id(layer.id)
                }
                inspectorField("Position") {
                    RotaSelect("Position", selection: Binding(get: { baseSettings.resolvedHUDPositions[layer.id] ?? .right },
                        set: { placeHUDLayer(layer.id, at: $0) }),
                        options: HUDLayerPosition.allCases.map { RotaOption($0.title, value: $0, systemImage: $0.symbol) },
                        showsTitle: false, fill: true)
                    .help("Where this HUD sits around Main HUD for two-finger navigation. Choosing an occupied spot swaps the two HUDs.")
                    .accessibilityIdentifier("hud-inspector-position")
                }
                inspectorField("Type") {
                    RotaSelect("Type", selection: Binding(get: { layer.builtIn }, set: { kind in
                        if kind != nil && !layer.favorites.isEmpty { pendingConversion = kind; confirmingConversion = true }
                        else { convertSelectedLayer(to: kind) }
                    }), options: [RotaOption("Custom HUD", value: HUDLayerBuiltIn?.none, systemImage: "square.3.layers.3d")] +
                        HUDLayerBuiltIn.allCases.map { RotaOption($0.title, value: Optional($0), systemImage: $0.symbol, section: "Built-in") },
                        showsTitle: false, fill: true)
                    .help("Turn this HUD into a built-in HUD. Its position, name and hotkeys are kept.")
                    .accessibilityIdentifier("hud-inspector-type")
                }
            } else if let group = settings.favorite(at: groupPath), let direction = groupPath.last {
                let path = groupPath
                inspectorField("Name") {
                    HUDInspectorNameField(name: group.name) { name in
                        guard var current = settings.favorite(at: path) else { return }
                        current.name = name
                        edit { $0.setFavorite(current, at: direction, in: Array(path.dropLast())) }
                    }.id(path)
                }
            }
            if let builtIn = generatedBuiltIn {
                Text(builtInDescription(builtIn)).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !editingWindowManager {
                inspectorField("Slots") {
                    RotaSelect("Slots", selection: Binding(get: { settings.count(at: groupPath) }, set: { count in
                        var next = settings
                        guard next.resize(to: count, at: groupPath) else {
                            groupError = "Remove some tiles before choosing fewer slots. Your existing tiles have been kept."; return
                        }
                        _ = save(next)
                    }), values: Array(2...16), showsTitle: false, fill: true) { "\($0) slots" }
                        .accessibilityIdentifier("hud-workspace-slots")
                }
                if !groupPath.isEmpty, settings.favorite(at: groupPath)?.isPureGroup == true {
                    inspectorField("Contents") {
                        RotaSelect("Contents", selection: Binding(get: { settings.favorite(at: groupPath)?.groupMode ?? .favorites }, set: { mode in
                            guard let direction = groupPath.last, var group = settings.favorite(at: groupPath) else { return }
                            group.groupMode = mode
                            edit { $0.setFavorite(group, at: direction, in: Array(groupPath.dropLast())) }
                        }), options: [
                            RotaOption("Assigned tiles", value: AppExplorerMode.favorites),
                            RotaOption("Recent apps", value: AppExplorerMode.recent),
                            RotaOption("Chrome tabs", value: AppExplorerMode.chromeTabs),
                            RotaOption("Recent apps & tabs", value: AppExplorerMode.recentAppsAndTabs)], showsTitle: false, fill: true)
                    }
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Button("Hotkeys & gestures…", systemImage: "keyboard") {
                    if !groupPath.isEmpty { openGroupHotkeys() }
                    else if let layer = selectedHoldLayer { creatingLayer = false; editingLayer = layer }
                    else { editingDefaultLayer = true }
                }
                .accessibilityIdentifier("hud-visual-actions")
                .help("Hold key, tap and swipe assignments for this HUD's actions")
                if editingWindowManager {
                    Button("Window commands…", systemImage: "macwindow") { workspaceDetails = true }
                        .accessibilityIdentifier("hud-layer-settings")
                }
                if generatedBuiltIn == nil && !editingWindowManager {
                    Button("Import bookmarks…", systemImage: "book.closed") { importingBookmarks = true }
                        .disabled(isRecentGroup || availableBookmarkSlots.isEmpty)
                        .help(availableBookmarkSlots.isEmpty ? "Remove a tile to make room for a bookmark." :
                            "Import Chrome or Safari bookmarks into empty tiles in this HUD.")
                }
                if !groupPath.isEmpty {
                    Button("Remove nested HUD…", systemImage: "trash", role: .destructive) { removingGroupPath = groupPath }
                } else if selectedHoldLayer != nil {
                    Button("Remove HUD…", systemImage: "trash", role: .destructive) { removingLayer = true }
                        .accessibilityIdentifier("hud-inspector-remove")
                }
            }
            .buttonStyle(.rotaGhost)
            if generatedBuiltIn == nil && !editingWindowManager {
                Text(isRecentGroup ? "Recent apps fill these tiles at runtime." :
                    "Click a tile to edit it here. Drag tiles to swap them. Clicks in the preview never launch anything.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .confirmationDialog("Replace this HUD's tiles?", isPresented: $confirmingConversion, presenting: pendingConversion) { kind in
            Button("Erase tiles and use \(kind.title)", role: .destructive) { convertSelectedLayer(to: kind) }
            Button("Cancel", role: .cancel) { pendingConversion = nil }
        } message: { kind in
            let count = selectedHoldLayer?.favorites.count ?? 0
            Text("Converting to \(kind.title) permanently erases the \(count) tile\(count == 1 ? "" : "s") in this HUD. Its position, name and hotkeys are kept.")
        }
    }

    private func convertSelectedLayer(to kind: HUDLayerBuiltIn?) {
        pendingConversion = nil
        guard let id = selectedLayerID else { return }
        var next = baseSettings
        guard next.convertLayer(id, to: kind) else {
            groupError = "This HUD couldn't be converted. Your existing tiles have been kept."; return
        }
        previewEditing = nil
        saveBase(next)
    }

    private func builtInDescription(_ builtIn: HUDLayerBuiltIn) -> String {
        switch builtIn {
        case .recentApps: return "Running apps fill this HUD. The active app is outlined on the left; other recent apps start at top-left and continue clockwise."
        case .chromeTabs: return "Open Chrome tabs fill this HUD. Swipe to a tab and lift to focus it. Allow Google Chrome under Privacy & Security → Automation if requested."
        case .recentAppsAndTabs: return "Recent apps and individual Chrome tabs share one most-recent-first list, so you can get back to where you were. The current app or tab is outlined on the left; the rest start at top-left and continue clockwise. Chrome itself appears only as its tabs."
        case .windowManager: return "Window positions, full screen, minimize and close."
        case .mediaControls: return "Volume, mute, previous/next track, and play/pause. Single tap plays or pauses."
        case .actions: return ExplorerReservedGroup.actions.summary
        case .slackChannels: return "The Slack channels you use most fill this HUD, most active first. Rotagivan learns them as you visit channels in Slack. Swipe to a channel and lift to jump there."
        }
    }

    private func inspectorField<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased()).font(.caption2.weight(.semibold)).tracking(0.8).foregroundStyle(.secondary)
            content()
        }
    }

    // MARK: Built-in defaults

    private func builtInDefaultPane(_ group: ExplorerReservedGroup) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(group.title, systemImage: group.symbol).font(.title3.weight(.semibold))
                Spacer()
                if group == .windowManager {
                    Button("Restore original…") { restoringDefaultWindow = true }
                }
            }
            Text("Built-in default · \(group.summary) New \(group.title) HUDs and tiles start from this layout.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                if group == .windowManager { WindowManagerSettingsView(store: store) }
                else { BuiltInHUDDefaultEditor(store: store, group: group) }
            }
        }
        .padding(20)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("hud-builtin-default-pane")
        .confirmationDialog("Restore the original Window Manager?", isPresented: $restoringDefaultWindow) {
            Button("Restore original", role: .destructive) {
                var next = store.settings.appExplorer ?? AppExplorerSettings()
                next.windowManager = nil; store.settings.appExplorer = next
            }
        } message: { Text("This resets the shared Window Manager layout and its custom bindings.") }
    }
}

/// Commits on Return or when focus leaves, so typing never saves per keystroke.
private struct HUDInspectorNameField: View {
    let name: String
    let onCommit: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Name", text: $draft)
            .textFieldStyle(.roundedBorder)
            .focused($focused)
            .onAppear { draft = name }
            .onChange(of: name) { _, value in if !focused { draft = value } }
            .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
            .onSubmit(commit)
            .accessibilityIdentifier("hud-inspector-name")
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 512, trimmed != name else { draft = name; return }
        onCommit(trimmed)
    }
}

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
            RotaSegmented("Operation", selection: $copy,
                options: [RotaOption("Move / swap", value: false), RotaOption("Copy", value: true)])
            RotaSelect("Destination HUD layer", selection: $destination,
                options: containers.map { RotaOption($0.title, value: $0.id) })
                .accessibilityIdentifier("explorer-transfer-container")
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
                    .buttonStyle(.rotaPrimary)
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
struct HUDWorkspaceViewportAnchors: PreferenceKey {
    static let defaultValue: [Anchor<CGRect>] = []
    static func reduce(value: inout [Anchor<CGRect>], nextValue: () -> [Anchor<CGRect>]) {
        value.append(contentsOf: nextValue())
    }
}

struct ExplorerHUDSettingsPreview: View {
    let settings: AppExplorerSettings
    let theme: ExplorerTheme
    let dictionary: [NamedHotkey]
    let groupPath: [ExplorerSlot]
    let layerName: String?
    var liveEntries: [ExplorerEntry]? = nil
    var liveMessage: String? = nil
    var chromeTabsProvider: @Sendable () -> [ChromeRecentTab] = { ChromeBookmarkTabs.snapshot() }
    var rootSettings: AppExplorerSettings? = nil
    var selectedLayerID: UUID? = nil
    var onSelectLayer: ((UUID?) -> Void)? = nil
    var onAddLayer: ((HUDLayerPosition) -> Void)? = nil
    @Binding var selection: ExplorerSlot
    var onBack: () -> Void
    var onDrag: (ExplorerSlot, ExplorerSlot?) -> Void
    var onDrop: (ExplorerSlot, ExplorerSlot?) -> Void
    var editingTile: Binding<ExplorerSlot?> = .constant(nil)
    var editor: ((ExplorerSlot) -> AnyView)? = nil
    // False when a docked inspector edits the selected tile instead of a popover.
    var editorPopover = true
    var workspace = false
    @StateObject private var model = ExplorerModel()
    @State private var chromePreviewTabs: [ChromeRecentTab] = []
    @State private var chromeLoadedKey: String?

    private var chromePreviewKey: String? {
        guard liveEntries == nil else { return nil }
        let builtIn = groupPath.isEmpty ? rootSettings?.holdLayers?.first(where: { $0.id == selectedLayerID })?.builtIn : nil
        guard settings.favorite(at: groupPath)?.isChromeTabsGroup == true || builtIn == .chromeTabs || mixed(builtIn) else { return nil }
        return (selectedLayerID?.uuidString ?? "group") + ":" + groupPath.map(\.rawValue).joined(separator: "/")
    }

    private func mixed(_ builtIn: HUDLayerBuiltIn?) -> Bool {
        settings.favorite(at: groupPath)?.isRecentAppsAndTabsGroup == true || builtIn == .recentAppsAndTabs
    }

    var body: some View {
        // Keep the fixed orbit canvas from imposing its 950-point ideal width
        // on the settings scroll view. The selected HUD stays at viewport center.
        GeometryReader { viewport in
        AppExplorerView(model: model, onSelect: { slot in
            if !model.showingRecents { selection = slot; if editor != nil { editingTile.wrappedValue = slot } }
        }, onCancel: {}, onBack: onBack, isPreview: true, settingsWorkspace: workspace,
            onPreviewLayer: onSelectLayer.map { select in { id in
                guard let node = rootSettings?.hudMap(includingUnavailable: true).first(where: { $0.id == id }) else { return }
                editingTile.wrappedValue = nil
                select(node.layerID)
            } },
            previewEmptyPositions: onAddLayer == nil ? [] : HUDLayerPosition.allCases.filter {
                !(rootSettings?.resolvedHUDPositions.values.contains($0) ?? true)
            },
            previewOrigin: rootSettings?.hudMap(includingUnavailable: true).first { $0.layerID == selectedLayerID }?.point ?? .zero,
            previewViewportSize: viewport.size,
            onPreviewAddLayer: onAddLayer,
            onPreviewDrag: { source, target in editingTile.wrappedValue = nil; model.selected = target; onDrag(source, target) },
            onPreviewDrop: { source, target in onDrop(source, target); model.selected = selection })
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("hud-layout-preview")
            .overlayPreferenceValue(ExplorerTileAnchors.self) { anchors in
                GeometryReader { proxy in
                    if editorPopover, let slot = editingTile.wrappedValue, let anchor = anchors[slot], let editor {
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
            .onChange(of: rootSettings) { _, _ in refresh() }
            .onChange(of: selectedLayerID) { _, _ in refresh() }
            .onChange(of: liveEntries) { _, _ in refresh() }
            .onChange(of: liveMessage) { _, _ in refresh() }
            .onChange(of: chromePreviewTabs) { _, _ in refresh() }
            .onChange(of: chromeLoadedKey) { _, _ in refresh() }
            .onChange(of: selection) { _, selected in model.selected = selected }
            .task(id: chromePreviewKey) {
                guard let key = chromePreviewKey else { return }
                let provider = chromeTabsProvider
                let tabs = await Task.detached(priority: .userInitiated) { provider() }.value
                guard !Task.isCancelled else { return }
                chromePreviewTabs = ChromeTabRecency.shared.ranked(tabs)
                chromeLoadedKey = key
            }
            .position(x: viewport.size.width / 2, y: viewport.size.height / 2)
        }
        .frame(height: workspace ? nil : 850)
        .anchorPreference(key: HUDWorkspaceViewportAnchors.self, value: .bounds) { workspace ? [$0] : [] }
        .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("HUD layout workspace")
        .accessibilityIdentifier(workspace ? "hud-workspace" : "hud-orbit-workspace")
    }

    private func refresh() {
        model.theme = theme
        model.animationsEnabled = settings.resolvedAnimationsEnabled
        model.mode = .favorites
        model.slotCount = settings.count(at: groupPath)
        model.layerName = layerName
        refreshCarousel()
        model.groupNames = groupPath.indices.compactMap { settings.favorite(at: Array(groupPath.prefix($0 + 1)))?.name }
        model.groupDirections = groupPath
        model.groupSlotCounts = groupPath.indices.map { settings.count(at: Array(groupPath.prefix($0))) }
        let builtIn = groupPath.isEmpty ? rootSettings?.holdLayers?.first(where: { $0.id == selectedLayerID })?.builtIn : nil
        let chrome = settings.favorite(at: groupPath)?.isChromeTabsGroup == true || builtIn == .chromeTabs
        let places = mixed(builtIn)
        model.showingRecents = settings.favorite(at: groupPath)?.isDynamicGroup == true || builtIn == .recentApps || chrome || places || liveEntries != nil
        model.selected = model.showingRecents ? nil : selection
        if model.showingRecents {
            if let liveEntries {
                model.entries = liveEntries
                model.message = liveMessage
                return
            }
            if places {
                let loaded = chromeLoadedKey == chromePreviewKey
                model.entries = loaded ? AppExplorerController.previewRecentPlaceEntries(tabs: chromePreviewTabs, count: model.slotCount) : []
                model.message = !loaded ? "Loading Chrome tabs…" : "Most recent app or Chrome tab on the left · the rest continue clockwise"
                return
            }
            if chrome {
                let loaded = chromeLoadedKey == chromePreviewKey
                model.entries = loaded ? chromeEntries(count: model.slotCount) : []
                model.message = !loaded ? "Loading Chrome tabs…" : chromePreviewTabs.isEmpty
                    ? "No Chrome tabs available. Open Chrome and allow Rotagivan in Privacy & Security → Automation."
                    : "Most recently used Chrome tabs · active tab on the left"
                return
            }
            let order = ExplorerSlot.slots(model.slotCount).sorted {
                ($0.angle + 180).truncatingRemainder(dividingBy: 360) < ($1.angle + 180).truncatingRemainder(dividingBy: 360)
            }
            model.entries = order.enumerated().map { index, slot in
                var entry = ExplorerEntry(direction: slot, bundleID: nil,
                    name: index == 0 ? "Active app" : "Recent app \(index)",
                    icon: NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil), url: nil)
                entry.isActiveApp = index == 0
                return entry
            }
            model.message = "Recent apps fill these positions at runtime · center goes back"
        } else {
            model.entries = (settings.favorites(at: groupPath) ?? []).map {
                AppExplorerController.makeEntry($0, depth: groupPath.count, dictionary: dictionary)
            }
            model.message = "Select a tile to edit · drag to move or swap"
        }
    }

    private func chromeEntries(count: Int) -> [ExplorerEntry] {
        let slots = ExplorerSlot.slots(count).sorted {
            ($0.angle + 180).truncatingRemainder(dividingBy: 360) < ($1.angle + 180).truncatingRemainder(dividingBy: 360)
        }
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome")
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        return chromePreviewTabs.prefix(count).enumerated().map { offset, tab in
            var entry = ExplorerEntry(direction: slots[offset], bundleID: "com.google.Chrome",
                name: tab.title.isEmpty ? tab.url : tab.title, icon: icon, url: URL(string: tab.url))
            entry.chromeTab = tab
            entry.isActiveApp = offset == 0
            return entry
        }
    }

    private func refreshCarousel() {
        guard let rootSettings else {
            model.carouselPreviews = []
            return
        }
        model.carouselPreviews = HUDCarouselPreview.makeMap(rootSettings.hudMap(includingUnavailable: true),
            activeLayerID: selectedLayerID) {
                AppExplorerController.makeEntry($0, depth: 0, dictionary: dictionary)
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
                Button("Done", action: onDone).keyboardShortcut(.defaultAction).buttonStyle(.rotaPrimary)
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
                    .keyboardShortcut(.defaultAction).buttonStyle(.rotaPrimary).disabled(trimmedName.isEmpty || trimmedName.count > 512)
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
                }.keyboardShortcut(.defaultAction).buttonStyle(.rotaPrimary).disabled(shortcut?.isValidExplorerShortcut != true || name.count > 512)
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
                }.keyboardShortcut(.defaultAction).buttonStyle(.rotaPrimary).disabled(validURL == nil || name.count > 512)
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
