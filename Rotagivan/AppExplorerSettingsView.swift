import SwiftUI
import UniformTypeIdentifiers

struct AppExplorerSettingsView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject private var shortcuts = ShortcutSettings.shared
    @State private var editingURLDirection: SwipeDirection?
    private let grid: [[SwipeDirection?]] = [[.topLeft, .up, .topRight], [.left, nil, .right], [.bottomLeft, .down, .bottomRight]]
    private var settings: AppExplorerSettings { store.settings.appExplorer ?? AppExplorerSettings() }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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
            Text("Favorites · fixed positions").font(.subheadline.weight(.medium))
            VStack(spacing: 6) {
                ForEach(0..<3) { row in
                    HStack(spacing: 6) {
                        ForEach(0..<3) { column in
                            if let direction = grid[row][column] { slot(direction) }
                            else {
                                Image(systemName: "safari").font(.largeTitle).foregroundStyle(.teal)
                                    .frame(maxWidth: .infinity).frame(height: 88)
                            }
                        }
                    }
                }
            }
            Text("Choose an app or web URL for each direction. URLs open in your default browser. Empty slots stay empty; missing apps keep their slot when syncing to another Mac.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .sheet(isPresented: Binding(get: { editingURLDirection != nil }, set: { if !$0 { editingURLDirection = nil } })) {
            if let direction = editingURLDirection {
                let favorite = settings.favorites.first { $0.direction == direction }
                ExplorerURLFavoriteEditor(direction: direction,
                    name: favorite?.url != nil ? (favorite?.name ?? "") : "",
                    address: favorite?.url ?? "", onSave: { favorite in
                        edit { $0.setFavorite(favorite, at: direction) }
                        editingURLDirection = nil
                    }, onCancel: { editingURLDirection = nil })
            }
        }
    }

    private func slot(_ direction: SwipeDirection) -> some View {
        let favorite = settings.favorites.first { $0.direction == direction }
        return VStack(spacing: 5) {
            Text(direction.title).font(.caption).foregroundStyle(.secondary)
            Menu {
                Button("Choose app…") { choose(direction) }
                Button(favorite?.url != nil ? "Edit URL…" : "Set URL…") { editingURLDirection = direction }
            } label: {
                Label(favorite?.name ?? "Choose…", systemImage: favorite?.url != nil ? "globe" : "app")
                    .lineLimit(1)
            }.padding(.horizontal, 6)
                .help(favorite?.url ?? "Choose an app or URL for \(direction.title)")
            if favorite != nil {
                Button("Remove") { edit { $0.setFavorite(nil, at: direction) } }
                    .font(.caption2).buttonStyle(.link)
            }
        }.frame(maxWidth: .infinity).frame(height: 88)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    }

    private func edit(_ update: (inout AppExplorerSettings) -> Void) {
        var next = settings; update(&next); store.settings.appExplorer = next
    }
    private func choose(_ direction: SwipeDirection) {
        let picker = NSOpenPanel()
        picker.title = "Choose \(direction.title) favorite"
        picker.allowedContentTypes = [.applicationBundle]
        picker.directoryURL = URL(fileURLWithPath: "/Applications")
        picker.allowsMultipleSelection = false
        guard picker.runModal() == .OK, let url = picker.url,
              let bundle = Bundle(url: url), let id = bundle.bundleIdentifier, id != "local.rotagivan" else { return }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        edit { $0.setFavorite(AppExplorerFavorite(direction: direction, bundleID: id, name: name), at: direction) }
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
