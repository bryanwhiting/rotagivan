import SwiftUI
import UniformTypeIdentifiers

struct ExplorerDestinationPicker: View {
    let direction: ExplorerSlot
    var onSave: (AppExplorerFavorite, ExplorerApplication?) -> Void
    var onCancel: () -> Void
    @State var query = ""
    @State private var urlName = ""
    @State private var applications: [ExplorerApplication] = []
    @State private var loading = true
    @State private var selectedID: String?
    @State private var error: String?
    @FocusState private var searchFocused: Bool

    // Inject a catalog for native UI tests; the real scan runs off the main thread.
    var loadApplications: @Sendable () -> [ExplorerApplication] = { ExplorerApplicationCatalog.scan() }
    private var results: [ExplorerApplication] { Array(ExplorerApplicationCatalog.search(query, in: applications).prefix(100)) }
    private var webURL: URL? { AppExplorerFavorite.webURL(query.trimmingCharacters(in: .whitespacesAndNewlines)) }
    private var selectedApp: ExplorerApplication? { results.first { $0.id == selectedID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("\(direction.title) · Choose app or URL", systemImage: "magnifyingglass").font(.headline)
            TextField("Search apps or paste https://…", text: $query)
                .textFieldStyle(.roundedBorder).focused($searchFocused).onSubmit { save() }
                .accessibilityIdentifier("explorer-destination-search")
            Text("Searches /Applications, ~/Applications (including Chrome apps), and macOS apps. Try “gchr” for Google Chrome.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let webURL {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        WebsiteFavicon(url: webURL, size: 24)
                        Text(webURL.host ?? "Website").font(.title3)
                    }
                    Text(webURL.absoluteString).font(.caption).textSelection(.enabled).lineLimit(3)
                    TextField("Website name (optional)", text: $urlName).textFieldStyle(.roundedBorder)
                    Text("Opens in your default browser. URLs sync with settings; avoid private sign-in links or URLs containing secrets.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading).frame(height: 300)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            } else {
                List(selection: $selectedID) {
                    ForEach(results) { app in
                        HStack(spacing: 10) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                                .resizable().scaledToFit().frame(width: 28, height: 28)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(app.name).lineLimit(1)
                                Text(app.location).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer(minLength: 0)
                        }.padding(.vertical, 3).tag(app.id)
                    }
                }.listStyle(.inset).frame(height: 300)
                    .overlay {
                        if loading { ProgressView("Finding applications…") }
                        else if results.isEmpty {
                            Text("No matching apps. Try fewer letters, paste a full https:// URL, or browse for an app.")
                                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(30)
                        }
                    }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Browse…", action: browse)
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button(webURL == nil ? "Add app" : "Add URL", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(webURL == nil ? selectedApp == nil : urlName.trimmingCharacters(in: .whitespacesAndNewlines).count > 512)
            }
        }.padding(22).frame(width: 540)
            .background(Color(nsColor: .windowBackgroundColor))
            .task {
                searchFocused = true
                let loader = loadApplications
                let loaded = await Task.detached(priority: .userInitiated) { loader() }.value
                guard !Task.isCancelled else { return }
                applications = loaded; loading = false
                selectedID = results.first?.id
            }
            .onChange(of: query) { _, _ in selectedID = results.first?.id; error = nil }
            .onMoveCommand { command in
                guard searchFocused, webURL == nil, !results.isEmpty else { return }
                let current = results.firstIndex { $0.id == selectedID } ?? 0
                if command == .down { selectedID = results[min(current + 1, results.count - 1)].id }
                if command == .up { selectedID = results[max(current - 1, 0)].id }
            }
    }

    private func save() {
        if let webURL {
            let name = urlName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard name.count <= 512 else { return }
            onSave(AppExplorerFavorite(direction: direction, name: name.isEmpty ? (webURL.host ?? "Website") : name,
                url: webURL.absoluteString), nil)
        } else if let app = selectedApp { save(app) }
    }

    private func save(_ app: ExplorerApplication) {
        guard let checked = ExplorerApplicationCatalog.application(at: app.url), checked.bundleID == app.bundleID else {
            error = "This application moved or is no longer available. Search again or use Browse."
            return
        }
        onSave(AppExplorerFavorite(direction: direction, bundleID: checked.bundleID, name: checked.name), checked)
    }

    private func browse() {
        let picker = NSOpenPanel()
        picker.title = "Choose \(direction.title) favorite"
        picker.allowedContentTypes = [.applicationBundle]
        picker.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        picker.allowsMultipleSelection = false
        guard picker.runModal() == .OK, let url = picker.url else { return }
        guard let app = ExplorerApplicationCatalog.application(at: url) else {
            error = "Choose a macOS application with a valid bundle identifier."
            return
        }
        save(app)
    }
}
