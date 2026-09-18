import SwiftUI
import UniformTypeIdentifiers

struct AppExplorerSettingsView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject private var shortcuts = ShortcutSettings.shared
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
            Text("Choose an app for each direction. Empty slots stay empty; favorites can launch closed apps. Missing apps keep their slot when syncing to another Mac.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func slot(_ direction: SwipeDirection) -> some View {
        let favorite = settings.favorites.first { $0.direction == direction }
        return VStack(spacing: 5) {
            Text(direction.title).font(.caption).foregroundStyle(.secondary)
            Button(favorite?.name ?? "Choose app…") { choose(direction) }
                .lineLimit(1).help("Choose the app for \(direction.title)")
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
