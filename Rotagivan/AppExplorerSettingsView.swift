import SwiftUI
import UniformTypeIdentifiers

struct AppExplorerSettingsView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject private var shortcuts = ShortcutSettings.shared
    @State private var editingURLPath: [SwipeDirection]?
    @State private var groupPath: [SwipeDirection]
    @State private var editingGroupPath: [SwipeDirection]?
    @State private var removingGroupPath: [SwipeDirection]?
    @State private var groupError: String?
    private let grid: [[SwipeDirection?]] = [[.topLeft, .up, .topRight], [.left, nil, .right], [.bottomLeft, .down, .bottomRight]]
    private var settings: AppExplorerSettings { store.settings.appExplorer ?? AppExplorerSettings() }
    private var favorites: [AppExplorerFavorite] { settings.favorites(at: groupPath) ?? [] }
    private var isRecentGroup: Bool { settings.favorite(at: groupPath)?.isRecentGroup == true }
    var compact = false
    var onGroupPathChange: (([SwipeDirection]) -> Void)? = nil

    init(store: SettingsStore, groupPath: [SwipeDirection] = [], compact: Bool = false,
         onGroupPathChange: (([SwipeDirection]) -> Void)? = nil) {
        self.store = store
        _groupPath = State(initialValue: groupPath)
        self.compact = compact
        self.onGroupPathChange = onGroupPathChange
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !compact {
            Label("App Explorer", systemImage: "safari").font(.headline)
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
            Text(isRecentGroup
                ? "Filled automatically with your most recently used other running apps. Starts on the left, then goes clockwise. The current app is excluded. Any assigned favorites are kept if you switch back. Tap the center in the HUD to go back."
                : "Choose an app, web URL, or named Explorer group for each direction. Groups can contain assigned favorites or recent apps. In the HUD, tap without swiping—or click the center—to go back. Empty slots stay empty when syncing.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
                        store.settings.appExplorer = next
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
        .onChange(of: groupPath) { _, path in onGroupPathChange?(path) }
    }

    private func slot(_ direction: SwipeDirection) -> some View {
        let favorite = favorites.first { $0.direction == direction }
        let icon = Self.applicationIcon(for: favorite)
        return VStack(spacing: 5) {
            Text(direction.title).font(.caption).foregroundStyle(.secondary)
            Menu {
                if favorite?.isGroup == true {
                    Button("Edit group…") { groupPath.append(direction) }
                    Button("Rename group…") { editingGroupPath = groupPath + [direction] }
                } else {
                    Button("Choose app…") { choose(direction) }
                    Button(favorite?.url != nil ? "Edit URL…" : "Set URL…") { editingURLPath = groupPath + [direction] }
                    Divider()
                    Button("New Explorer group…") { editingGroupPath = groupPath + [direction] }
                        .disabled(groupPath.count >= AppExplorerSettings.maximumGroupDepth)
                    Button("New Recent apps group") {
                        var next = settings
                        let group = AppExplorerFavorite(direction: direction, name: "Recent apps", children: [], groupMode: .recent)
                        guard next.setFavorite(group, at: direction, in: groupPath), next.hasValidFavorites else {
                            groupError = "The parent group must still exist and stay within the group limits."
                            return
                        }
                        store.settings.appExplorer = next
                        groupError = nil
                        groupPath.append(direction)
                    }.disabled(groupPath.count >= AppExplorerSettings.maximumGroupDepth)
                }
            } label: {
                Label {
                    Text(favorite?.name ?? "Choose…").lineLimit(1)
                } icon: {
                    if let icon {
                        Image(nsImage: icon).resizable().renderingMode(.original)
                            .scaledToFit().frame(width: 16, height: 16)
                    } else {
                        Image(systemName: favorite?.isRecentGroup == true ? "clock.arrow.circlepath" : (favorite?.isGroup == true ? "folder.fill" : (favorite?.url != nil ? "globe" : "app")))
                            .frame(width: 16, height: 16)
                    }
                }
            }.padding(.horizontal, 6)
                .help(favorite?.url ?? (favorite?.isGroup == true ? "Open \(favorite!.name) to edit its eight slots" : "Choose an app, URL, or group for \(direction.title)"))
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
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
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
        groupError = nil; store.settings.appExplorer = next
    }

    static func applicationIcon(for favorite: AppExplorerFavorite?) -> NSImage? {
        guard let favorite, !favorite.isGroup, favorite.url == nil, let bundleID = favorite.bundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        // Native menu labels use NSImage's intrinsic size, not just the SwiftUI
        // frame. Copy before sizing so the workspace's cached icon is untouched.
        let icon = NSWorkspace.shared.icon(forFile: url.path).copy() as? NSImage
        icon?.size = NSSize(width: 16, height: 16)
        return icon
    }
    private func choose(_ direction: SwipeDirection) {
        let path = groupPath
        let picker = NSOpenPanel()
        picker.title = "Choose \(direction.title) favorite"
        picker.allowedContentTypes = [.applicationBundle]
        picker.directoryURL = URL(fileURLWithPath: "/Applications")
        picker.allowsMultipleSelection = false
        guard picker.runModal() == .OK, let url = picker.url,
              let bundle = Bundle(url: url), let id = bundle.bundleIdentifier, id != "local.rotagivan" else { return }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        edit { $0.setFavorite(AppExplorerFavorite(direction: direction, bundleID: id, name: name), at: direction, in: path) }
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
