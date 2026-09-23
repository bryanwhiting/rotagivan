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

struct ExplorerBookmarkImporter: View {
    let capacity: Int
    let existingURLs: Set<String>
    var onImport: ([BrowserBookmark]) -> Bool
    var onCancel: () -> Void
    var loadBookmarks: @Sendable (BrowserBookmarkSource, URL?) throws -> [BrowserBookmark] = {
        try BrowserBookmarkLoader.load($0, from: $1)
    }

    @State private var source: BrowserBookmarkSource = .chrome
    @State private var bookmarks: [BrowserBookmark] = []
    @State private var selection = Set<String>()
    @State private var query = ""
    @State private var loading = true
    @State private var error: String?
    @FocusState private var searchFocused: Bool

    private var results: [BrowserBookmark] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return bookmarks }
        return bookmarks.filter {
            ($0.title + " " + $0.url.absoluteString + " " + $0.location)
                .localizedCaseInsensitiveContains(needle)
        }
    }
    private var selectedBookmarks: [BrowserBookmark] { bookmarks.filter { selection.contains($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Label("Import browser bookmarks", systemImage: "book.closed.fill").font(.title2.weight(.semibold))
                Spacer()
                Text("\(capacity) open \(capacity == 1 ? "slot" : "slots")")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(.quaternary, in: Capsule())
            }

            Picker("Browser", selection: $source) {
                ForEach(BrowserBookmarkSource.allCases) { browser in
                    Label(browser.title, systemImage: browser.symbol).tag(browser)
                }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search names, URLs, folders, or Chrome profiles", text: $query)
                    .textFieldStyle(.plain).focused($searchFocused)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 11).frame(height: 32)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.12)))

            HStack {
                Text(loading ? "Reading \(source.title)…" : "\(results.count) bookmarks")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Select visible") { selectVisible() }
                    .disabled(loading || results.allSatisfy { existingURLs.contains($0.url.absoluteString) })
                Button("Clear") { selection.removeAll() }.disabled(selection.isEmpty)
            }
            .controlSize(.small)

            List {
                ForEach(results) { bookmark in
                    bookmarkRow(bookmark)
                }
            }
            .listStyle(.inset)
            .overlay {
                if loading { ProgressView("Reading \(source.title) bookmarks…") }
                else if let error {
                    ContentUnavailableView("Bookmarks unavailable", systemImage: "book.closed",
                        description: Text(error))
                } else if results.isEmpty {
                    ContentUnavailableView(query.isEmpty ? "No web bookmarks found" : "No matching bookmarks",
                        systemImage: "magnifyingglass", description: Text(query.isEmpty ?
                            "Choose the browser’s bookmark file manually if it lives somewhere else." : "Try another name, URL, or folder."))
                }
            }

            HStack(alignment: .center) {
                Button("Choose \(source.fileName)…", action: chooseFile)
                Text("Only http:// and https:// bookmarks are shown. Imported URLs use the site favicon and sync with this profile.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 10)
            }

            Divider()
            HStack {
                Text(selection.isEmpty ? "Select up to \(capacity) bookmarks" :
                    "\(selection.count) of \(capacity) selected")
                    .font(.caption.weight(.semibold)).foregroundStyle(selection.isEmpty ? Color.secondary : Color.accentColor)
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Import \(selection.count) \(selection.count == 1 ? "bookmark" : "bookmarks")") {
                    guard onImport(selectedBookmarks) else {
                        error = "The HUD layer changed while this sheet was open. Review its open slots and try again."
                        return
                    }
                }
                .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(selection.isEmpty)
            }
        }
        .padding(22).frame(width: 680, height: 620)
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: source) { await load() }
        .onAppear { searchFocused = true }
    }

    private func bookmarkRow(_ bookmark: BrowserBookmark) -> some View {
        let imported = existingURLs.contains(bookmark.url.absoluteString)
        let selected = selection.contains(bookmark.id)
        let atCapacity = selection.count >= capacity && !selected
        return Button {
            guard !imported else { return }
            if selected { selection.remove(bookmark.id) }
            else if !atCapacity { selection.insert(bookmark.id) }
        } label: {
            HStack(spacing: 11) {
                Image(systemName: imported ? "checkmark.circle" : (selected ? "checkmark.circle.fill" : "circle"))
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(imported ? Color.secondary : (selected ? Color.accentColor : Color.secondary))
                    .frame(width: 20)
                WebsiteFavicon(url: bookmark.url, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(bookmark.title).fontWeight(.medium).lineLimit(1)
                    Text(bookmark.url.absoluteString).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    if !bookmark.location.isEmpty {
                        Label(bookmark.location, systemImage: "folder")
                            .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if imported { Text("Already added").font(.caption).foregroundStyle(.secondary) }
            }
            .padding(.vertical, 4).contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(imported || atCapacity)
        .accessibilityLabel("\(bookmark.title), \(imported ? "already added" : (selected ? "selected" : "not selected"))")
    }

    private func selectVisible() {
        for bookmark in results where !existingURLs.contains(bookmark.url.absoluteString) {
            guard selection.count < capacity else { break }
            selection.insert(bookmark.id)
        }
    }

    @MainActor private func load(file: URL? = nil) async {
        loading = true; error = nil; bookmarks = []; selection = []; query = ""
        let browser = source, loader = loadBookmarks
        let outcome = await Task.detached(priority: .userInitiated) { () -> (values: [BrowserBookmark], error: String?) in
            do { return (try loader(browser, file), nil) }
            catch { return ([], error.localizedDescription) }
        }.value
        guard !Task.isCancelled else { return }
        bookmarks = outcome.values
        error = outcome.error
        loading = false
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose \(source.title) \(source.fileName)"
        panel.message = source == .safari ?
            "Safari may require you to grant access to ~/Library/Safari/Bookmarks.plist." :
            "Choose a Chrome profile’s Bookmarks file."
        panel.directoryURL = BrowserBookmarkLoader.suggestedDirectory(for: source)
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowsOtherFileTypes = true
        if source == .safari { panel.allowedContentTypes = [.propertyList] }
        guard panel.runModal() == .OK, let file = panel.url else { return }
        Task { await load(file: file) }
    }
}
