import SwiftUI

struct AppExplorerSettingsView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject private var shortcuts = ShortcutSettings.shared
    @State private var editingURLPath: [SwipeDirection]?
    @State private var editingShortcutPath: [SwipeDirection]?
    @State private var selectedLayerID: UUID?
    @State private var editingLayer: ExplorerHoldLayer?
    @State private var creatingLayer = false
    @State private var removingLayer = false
    @State private var editingApplicationPath: [SwipeDirection]?
    @State private var groupPath: [SwipeDirection]
    @State private var editingGroupPath: [SwipeDirection]?
    @State private var removingGroupPath: [SwipeDirection]?
    @State private var groupError: String?
    @State private var slotSpace = UUID()
    @State private var slotFrames: [SwipeDirection: CGRect] = [:]
    @State private var slotDrag: ExplorerSlotDrag?
    @State private var dropTarget: SwipeDirection?
    private let grid: [[SwipeDirection?]] = [[.topLeft, .up, .topRight], [.left, nil, .right], [.bottomLeft, .down, .bottomRight]]
    private var baseSettings: AppExplorerSettings { store.settings.appExplorer ?? AppExplorerSettings() }
    private var settings: AppExplorerSettings { baseSettings.projected(layerID: selectedLayerID) }
    private var favorites: [AppExplorerFavorite] { settings.favorites(at: groupPath) ?? [] }
    private var isRecentGroup: Bool { settings.favorite(at: groupPath)?.isRecentGroup == true }
    private var themeBinding: Binding<ExplorerTheme> {
        Binding(get: { baseSettings.resolvedTheme }, set: { theme in
            var next = baseSettings; next.theme = theme; store.settings.appExplorer = next
        })
    }
    private var animationBinding: Binding<Bool> {
        Binding(get: { baseSettings.resolvedAnimationsEnabled }, set: { enabled in
            var next = baseSettings; next.animationsEnabled = enabled; store.settings.appExplorer = next
        })
    }
    var compact = false
    var onGroupPathChange: (([SwipeDirection]) -> Void)? = nil

    init(store: SettingsStore, groupPath: [SwipeDirection] = [], compact: Bool = false, initialLayerID: UUID? = nil,
         onGroupPathChange: (([SwipeDirection]) -> Void)? = nil) {
        self.store = store
        _groupPath = State(initialValue: groupPath)
        _selectedLayerID = State(initialValue: initialLayerID)
        self.compact = compact
        self.onGroupPathChange = onGroupPathChange
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !compact && selectedLayerID == nil {
            Label("App Explorer", systemImage: "safari").font(.headline)
            ExplorerThemePicker(theme: themeBinding)
            Toggle("Animate HUD feedback", isOn: animationBinding).font(.caption)
            Text("Appearance applies to apps, groups, window layouts, and media controls. Reduce Motion always disables animations.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("Default mode", selection: Binding(get: { settings.defaultMode }, set: { mode in
                edit { $0.defaultMode = mode }
            })) {
                ForEach(AppExplorerMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
            HStack {
                Text("Hold for \(settings.defaultMode.alternate.title.lowercased())")
                ShortcutRecorder(title: settings.holdShortcut?.displayName ?? "Record shortcut…") { key in
                    edit { $0.holdShortcut = key }
                }.frame(width: 200, height: 26)
                if settings.holdShortcut != nil {
                    Button("Clear") { edit { $0.holdShortcut = nil } }
                }
            }
            Text("Your App Explorer gesture opens the default mode. Hold this shortcut to open the other mode; swipe and lift to choose before releasing the key. Releasing without a selection cancels.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error = shortcuts.error { Text(error).font(.caption).foregroundStyle(.orange) }
            }
            HStack {
                if compact {
                    Menu {
                        Picker("Theme", selection: themeBinding) {
                            ForEach(ExplorerTheme.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        Toggle("Animate HUD feedback", isOn: animationBinding)
                    } label: { Image(systemName: "paintpalette") }
                        .menuStyle(.borderlessButton).fixedSize().help("Explorer appearance")
                }
                Picker("Explorer layer", selection: $selectedLayerID) {
                    Text("Default").tag(nil as UUID?)
                    ForEach(baseSettings.holdLayers ?? []) { layer in Text(layer.name).tag(Optional(layer.id)) }
                }
                Button("Add layer") {
                    creatingLayer = true
                    let y = RecordedShortcut(keyCode: 16, modifiers: 0, keyLabel: "Y")
                    let used = (baseSettings.holdLayers ?? []).contains { $0.holdShortcut?.keyCode == y.keyCode && $0.holdShortcut?.modifiers == 0 }
                    editingLayer = ExplorerHoldLayer(name: "New layer", holdShortcut: used ? nil : y, favorites: settings.favorites, windowLayout: .thirds)
                }.disabled((baseSettings.holdLayers ?? []).count >= 16)
                if let layer = baseSettings.holdLayers?.first(where: { $0.id == selectedLayerID }) {
                    Button("Edit…") { creatingLayer = false; editingLayer = layer }
                    Button("Remove", role: .destructive) { removingLayer = true }
                }
            }.font(.subheadline)
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
            if let groupError { Text(groupError).font(.caption).foregroundStyle(.red) }
            VStack(spacing: 6) {
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
            .coordinateSpace(name: slotSpace)
            .onPreferenceChange(ExplorerSlotFramesKey.self) { slotFrames = $0 }
            Text(isRecentGroup
                ? "Filled automatically with your most recently used other running apps. Starts on the left, then goes clockwise. The current app is excluded. Any assigned favorites are kept if you switch back. Tap the center in the HUD to go back."
                : "Drag an icon or name to another slot to swap; drop into an empty slot to move. Use ••• to choose apps, URLs, shortcuts, or groups. Changes save automatically. Tap the center in the HUD to go back.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
                store.settings.appExplorer = next
                selectedLayerID = updated.id; groupPath = []; editingLayer = nil; groupError = nil
            }, onCancel: { editingLayer = nil })
        }
        .confirmationDialog("Remove this Explorer layer and all its slots?", isPresented: $removingLayer, titleVisibility: .visible) {
            Button("Remove layer", role: .destructive) {
                var next = baseSettings
                next.holdLayers?.removeAll { $0.id == selectedLayerID }
                store.settings.appExplorer = next
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
                        let group = AppExplorerFavorite(direction: direction, name: name,
                            children: next.favorite(at: path)?.children ?? [],
                            groupMode: next.favorite(at: path)?.groupMode)
                        guard next.setFavorite(group, at: direction, in: Array(path.dropLast())), next.hasValidFavorites else {
                            groupError = "Groups support four levels and 256 total favorites. The parent group must still exist."
                            editingGroupPath = nil
                            return
                        }
                        guard save(next) else { return }
                        groupError = nil; editingGroupPath = nil; groupPath = path
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
        .onChange(of: selectedLayerID) { _, _ in groupPath = []; groupError = nil; slotDrag = nil; dropTarget = nil }
        .onChange(of: baseSettings.holdLayers) { _, layers in
            if let selectedLayerID, layers?.contains(where: { $0.id == selectedLayerID }) != true { self.selectedLayerID = nil }
        }
        .onChange(of: groupPath) { _, path in onGroupPathChange?(path) }
        .onDisappear { slotDrag = nil; dropTarget = nil }
    }

    private func slot(_ direction: SwipeDirection) -> some View {
        let favorite = favorites.first { $0.direction == direction }
        let icon = Self.applicationIcon(for: favorite)
        return VStack(spacing: 5) {
            HStack {
                Text(direction.title).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Menu {
                    if favorite?.isGroup == true {
                        Button("Edit group…") { groupPath.append(direction) }
                        Button("Rename group…") { editingGroupPath = groupPath + [direction] }
                    } else {
                        Button("Choose app or URL…") { editingApplicationPath = groupPath + [direction] }
                        Button(favorite?.url != nil ? "Edit URL…" : "Set URL…") { editingURLPath = groupPath + [direction] }
                        Button(favorite?.shortcut != nil ? "Edit shortcut…" : "Set shortcut…") { editingShortcutPath = groupPath + [direction] }
                        Divider()
                        Button("Window Manager") {
                            edit { $0.setFavorite(AppExplorerFavorite(direction: direction, name: "Window Manager", action: .windowManager), at: direction, in: groupPath) }
                        }
                        Button("Media Controls") {
                            edit { $0.setFavorite(AppExplorerFavorite(direction: direction, name: "Media Controls", action: .mediaControls), at: direction, in: groupPath) }
                        }
                        Button("New Explorer group…") { editingGroupPath = groupPath + [direction] }
                            .disabled(groupPath.count >= AppExplorerSettings.maximumGroupDepth)
                        Button("New Recent apps group") {
                            var next = settings
                            let group = AppExplorerFavorite(direction: direction, name: "Recent apps", children: [], groupMode: .recent)
                            guard next.setFavorite(group, at: direction, in: groupPath), next.hasValidFavorites else {
                                groupError = "The parent group must still exist and stay within the group limits."
                                return
                            }
                            guard save(next) else { return }
                            groupError = nil
                            groupPath.append(direction)
                        }.disabled(groupPath.count >= AppExplorerSettings.maximumGroupDepth)
                    }
                    if favorite != nil {
                        Divider()
                        Menu("Move or swap with") {
                            ForEach(SwipeDirection.allCases.filter { $0 != direction }, id: \.self) { target in
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
                    Text(favorite.name).lineLimit(1)
                } icon: {
                    if let icon {
                        Image(nsImage: icon).resizable().renderingMode(.original)
                            .scaledToFit().frame(width: 16, height: 16)
                    } else if favorite.action == .mediaControls {
                        Image(systemName: "speaker.wave.2.fill").foregroundStyle(.teal).frame(width: 16, height: 16)
                    } else if favorite.shortcut != nil {
                        Image(systemName: "keyboard").foregroundStyle(.teal).frame(width: 16, height: 16)
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
                        Button("Edit group") { groupPath.append(direction) }
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

    private func updateSlotDrag(from source: SwipeDirection, at point: CGPoint) {
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

    private func recentSlot(_ direction: SwipeDirection) -> some View {
        let rank = (AppExplorerSettings.recentDirections.firstIndex(of: direction) ?? 0) + 1
        return VStack(spacing: 5) {
            Text(direction.title).font(.caption).foregroundStyle(.secondary)
            Text("\(rank)").font(.title2.weight(.semibold)).foregroundStyle(.teal)
            Text(rank == 1 ? "Most recent" : "Recent app \(rank)").font(.caption)
        }.frame(maxWidth: .infinity).frame(height: 88)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    }

    private func edit(_ update: (inout AppExplorerSettings) -> Void) {
        var next = settings; update(&next)
        guard next.hasValidFavorites else { groupError = "Use at most eight slots per group, four group levels, and 256 total favorites."; return }
        _ = save(next)
    }

    @discardableResult private func save(_ settings: AppExplorerSettings) -> Bool {
        var next = settings
        if let selectedLayerID {
            next = baseSettings
            guard let index = next.holdLayers?.firstIndex(where: { $0.id == selectedLayerID }) else { groupError = "This layer was removed. Select another layer."; return false }
            next.holdLayers?[index].favorites = settings.favorites
        }
        guard next.hasValidFavorites else { groupError = "Use unique hold keys and stay within the 16-layer / 256-slot limits."; return false }
        store.settings.appExplorer = next
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

private struct ExplorerSlotFramesKey: PreferenceKey {
    static let defaultValue: [SwipeDirection: CGRect] = [:]
    static func reduce(value: inout [SwipeDirection: CGRect], nextValue: () -> [SwipeDirection: CGRect]) {
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

struct ExplorerInlineEditor: View {
    @ObservedObject var store: SettingsStore
    var groupPath: [SwipeDirection]
    var onGroupPathChange: ([SwipeDirection]) -> Void
    var onDone: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("Edit App Explorer", systemImage: "pencil").font(.title3.weight(.semibold))
                Spacer()
                Button("Done", action: onDone).keyboardShortcut(.defaultAction)
            }
            AppExplorerSettingsView(store: store, groupPath: groupPath, compact: true,
                onGroupPathChange: onGroupPathChange)
            Text("Changes save automatically · taps click while editing · swipe shortcuts resume when you finish")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(26).frame(width: 680)
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
    let direction: SwipeDirection
    @State var name: String
    @State var shortcut: RecordedShortcut?
    var onSave: (AppExplorerFavorite) -> Void
    var onCancel: () -> Void
    @State private var action: TapAction = .shortcut

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("\(direction.title) · Keyboard shortcut", systemImage: "keyboard").font(.headline)
            TextField("Name (optional)", text: $name).textFieldStyle(.roundedBorder)
            TapActionEditor(title: "Shortcut to send", action: $action, shortcut: $shortcut, keyboardOnly: true)
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
    let direction: SwipeDirection
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
