import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum ActionPickerCategory: String, CaseIterable, Identifiable {
    case all = "All actions", shortcuts = "Shortcuts", macros = "Macros", apps = "Applications"
    case mac = "Mac controls", windows = "Windows", media = "Audio & media", hud = "HUD layers", pointer = "Pointer"
    var id: Self { self }
    var symbol: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .shortcuts: return "keyboard"
        case .macros: return "square.stack.3d.up"
        case .apps: return "app.dashed"
        case .mac: return "macbook"
        case .windows: return "macwindow"
        case .media: return "speaker.wave.2"
        case .hud: return "circle.hexagongrid"
        case .pointer: return "cursorarrow"
        }
    }
}

struct ActionPickerItem: Identifiable {
    let action: BindingAction
    let category: ActionPickerCategory
    let title: String
    let detail: String
    var id: String { action.identity }
    var symbol: String { action.pickerSymbol }
}

extension BindingAction {
    var pickerSymbol: String {
        switch kind {
        case .keystroke: return "keyboard"
        case .macro: return "square.stack.3d.up"
        case .hudLayer: return "circle.hexagongrid"
        case .hudNavigation: return hudNavigation?.symbol ?? "circle.hexagongrid"
        case .openApp: return "app"
        case .openURL: return "globe"
        case .command: return command?.symbol ?? "macwindow"
        case .media: return media?.symbol ?? "speaker.wave.2"
        case .windowPlacement: return "rectangle.split.2x2"
        case .tap: return "hand.tap"
        }
    }
}

enum ActionPickerCatalog {
    static func make(dictionary: [NamedHotkey], layers: [ExplorerHoldLayer], destinations: [HUDActionDestination],
                     applications: [ExplorerApplication], allowPointer: Bool) -> [ActionPickerItem] {
        var items: [ActionPickerItem] = []
        var seen = Set<String>()
        func add(_ action: BindingAction, _ category: ActionPickerCategory, detail: String? = nil) {
            guard action.isValid, seen.insert(action.identity).inserted else { return }
            items.append(ActionPickerItem(action: action, category: category,
                title: dictionary.title(for: action), detail: detail ?? action.description))
        }
        CommonMacShortcut.all.forEach { add($0.action, .shortcuts, detail: $0.detail) }
        dictionary.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .forEach { add(.macro($0), .macros, detail: $0.summary) }
        AppExplorerAction.macOSCommands.forEach { add(.command($0), .mac) }
        AppExplorerAction.windowCommands.forEach { add(.command($0), .windows) }
        for layout in ExplorerWindowLayout.allCases {
            for direction in SwipeDirection.allCases {
                add(.windowPlacement(ExplorerWindowPlacement(direction: direction, layout: layout)), .windows)
            }
        }
        ExplorerMediaAction.allCases.forEach { add(.media($0), .media) }
        add(.command(.mediaControls), .hud)
        add(.command(.windowManager), .hud)
        add(.command(.activateVoiceMode), .hud)
        HUDNavigationAction.allCases.forEach { add(.hudNavigation($0), .hud) }
        if destinations.isEmpty {
            add(.hudLayer(nil), .hud)
            layers.forEach { add(.hudLayer($0), .hud) }
        } else { destinations.forEach { add(.hudDestination($0), .hud) } }
        applications.forEach { add(.openApp(bundleID: $0.bundleID, name: $0.name), .apps) }
        if allowPointer {
            [TapAction.leftClick, .doubleLeftClick, .tripleLeftClick, .rightClick, .appExplorer,
             .windowManager, .enter, .optionF19].forEach { add(.tap($0), .pointer) }
        }
        return items
    }

    static func search(_ items: [ActionPickerItem], query: String, category: ActionPickerCategory) -> [ActionPickerItem] {
        let tokens = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split(whereSeparator: \.isWhitespace)
        return items.filter { item in
            guard category == .all || item.category == category else { return false }
            let text = (item.title + " " + item.detail + " " + item.category.rawValue)
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            return tokens.allSatisfy { text.contains($0) }
        }.sorted {
            let a = $0.title.localizedStandardContains(query), b = $1.title.localizedStandardContains(query)
            if a != b { return a }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }
}

/// A draft-only picker. Browsing never executes actions or changes assignments.
struct ActionPickerModal: View {
    let current: BindingAction
    let dictionary: [NamedHotkey]
    let layers: [ExplorerHoldLayer]
    let destinations: [HUDActionDestination]
    var allowPointerActions = true
    var loadApplications: (@Sendable () -> [ExplorerApplication])? = nil
    @ObservedObject var applicationIndex = VoiceApplicationIndex.shared
    let onSelect: (BindingAction) -> Void
    let onCancel: () -> Void
    @State private var applications: [ExplorerApplication] = []
    @State private var loadingApps = true
    @State private var query = ""
    @State private var category = ActionPickerCategory.all
    @State private var selectedID: String?
    @State private var custom: String?
    @State private var draft: BindingAction?
    @State private var url = "https://"

    private var items: [ActionPickerItem] {
        ActionPickerCatalog.make(dictionary: dictionary, layers: layers, destinations: destinations,
            applications: loadApplications == nil ? applicationIndex.applications : applications, allowPointer: allowPointerActions)
    }
    private var results: [ActionPickerItem] { ActionPickerCatalog.search(items, query: query, category: category) }
    private var selected: BindingAction? {
        if custom != nil { return draft }
        return results.first { $0.id == selectedID }?.action
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Choose an action").font(.system(size: 23, weight: .semibold))
                        Text("Find what you want to do. Assign it anywhere.").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "command").font(.system(size: 23, weight: .light))
                        .foregroundStyle(Color.accentColor).frame(width: 42, height: 42)
                        .background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
                }
                HStack(spacing: 9) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    ActionPickerSearchField(query: $query, move: moveSelection, confirm: confirm, cancel: onCancel)
                        .frame(height: 18)
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain).accessibilityLabel("Clear search")
                    }
                }
                .padding(12).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.1)))
            }.padding(24)
            Divider()
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 4) {
                    ForEach(ActionPickerCategory.allCases.filter { allowPointerActions || $0 != .pointer }) { value in
                        Button {
                            category = value; custom = nil; draft = nil; selectFirst()
                        } label: {
                            Label(value.rawValue, systemImage: value.symbol)
                                .font(.system(size: 12, weight: category == value && custom == nil ? .semibold : .regular))
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 5)
                                .background(category == value && custom == nil ? Color.accentColor.opacity(0.12) : .clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain).accessibilityAddTraits(category == value && custom == nil ? .isSelected : [])
                    }
                    }
                    }
                    Divider().padding(.vertical, 6)
                    Text("CREATE YOUR OWN").font(.system(size: 9, weight: .semibold)).tracking(0.7).foregroundStyle(.secondary).padding(.horizontal, 10)
                    Button { custom = "Keystroke"; draft = nil } label: { Label("Record keystroke", systemImage: "keyboard") }
                        .buttonStyle(.plain).padding(8)
                    Button { custom = "Website"; url = current.kind == .openURL ? current.url ?? "https://" : "https://"; draft = .openURL(url) } label: { Label("Open a website", systemImage: "link") }
                        .buttonStyle(.plain).padding(8)
                    Button(action: browseApplication) { Label("Browse for app…", systemImage: "folder") }
                        .buttonStyle(.plain).padding(8)
                }.font(.system(size: 11)).lineLimit(1).padding(12)
                .frame(width: 172).background(Color.primary.opacity(0.025))
                Divider()
                VStack(spacing: 0) {
                    if let custom {
                        customEditor(custom)
                    } else {
                        HStack {
                            Text(category.rawValue).font(.system(size: 12, weight: .semibold))
                            Spacer()
                            Text("\(results.count) actions").font(.caption).foregroundStyle(.secondary)
                            if loadingApps { ProgressView().controlSize(.mini).help("Loading installed applications") }
                        }.padding(.horizontal, 18).padding(.vertical, 12)
                        if results.isEmpty {
                            VStack(spacing: 10) {
                                Image(systemName: "magnifyingglass").font(.system(size: 28)).foregroundStyle(.tertiary)
                                Text("No matching actions").font(.headline)
                                Text("Try another search or choose a different category.").font(.caption).foregroundStyle(.secondary)
                                Button("Search all actions") { category = .all; query = ""; selectFirst() }
                            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            ScrollViewReader { scroll in
                            List(selection: $selectedID) {
                                ForEach(results) { item in
                                    HStack(spacing: 12) {
                                        Image(systemName: item.symbol).font(.system(size: 16))
                                            .frame(width: 34, height: 34)
                                            .background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(item.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                            Text(item.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                                        }
                                        Spacer(minLength: 0)
                                    }.padding(.vertical, 5).tag(item.id).id(item.id)
                                        .accessibilityElement(children: .combine)
                                }
                            }.listStyle(.inset).accessibilityIdentifier("action-picker-results")
                                .onChange(of: selectedID) { _, id in if let id { scroll.scrollTo(id) } }
                                .onAppear { if let selectedID { scroll.scrollTo(selectedID) } }
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(selected.map { dictionary.title(for: $0) } ?? "Select an action")
                        .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text(selected?.description ?? "Nothing changes until you choose Use action.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Use action", action: confirm).buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction).disabled(selected?.isValid != true)
                    .accessibilityIdentifier("action-picker-confirm")
            }.padding(20)
        }
        .frame(width: 760, height: 620)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { selectedID = current.identity; if selected == nil { selectFirst() } }
        .onChange(of: query) { _, _ in
            custom = nil; draft = nil
            if !results.contains(where: { $0.id == selectedID }) { selectFirst() }
        }
        .task {
            if let loader = loadApplications {
                let loaded = await Task.detached(priority: .userInitiated) { loader() }.value
                guard !Task.isCancelled else { return }
                applications = loaded
            } else {
                await applicationIndex.load()
            }
            guard !Task.isCancelled else { return }
            loadingApps = false
            if selectedID == nil { selectFirst() }
        }
    }

    private func browseApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url,
                  let app = ExplorerApplicationCatalog.application(at: url) else { return }
            if !applications.contains(where: { $0.bundleID == app.bundleID }) { applications.append(app) }
            custom = nil; draft = nil; category = .apps; query = app.name
            selectedID = BindingAction.openApp(bundleID: app.bundleID, name: app.name).identity
        }
    }

    private func moveSelection(_ delta: Int) {
        guard custom == nil, !results.isEmpty else { return }
        let index = results.firstIndex { $0.id == selectedID } ?? 0
        selectedID = results[max(0, min(index + delta, results.count - 1))].id
    }

    private func selectFirst() { selectedID = results.first?.id }
    private func confirm() { if let selected, selected.isValid { onSelect(selected) } }

    private func customEditor(_ name: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: name == "Website" ? "link" : "keyboard")
                .font(.system(size: 30, weight: .light)).foregroundStyle(Color.accentColor)
            Text(name == "Website" ? "Open a website" : "Record a keystroke").font(.title2.weight(.semibold))
            Text(name == "Website" ? "Enter an http or https address. This action opens it in your default browser." :
                "Press the key combination you want this action to send. This is the output, not the trigger.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if name == "Website" {
                TextField("https://example.com", text: $url).textFieldStyle(.roundedBorder)
                    .onChange(of: url) { _, value in draft = .openURL(value.trimmingCharacters(in: .whitespacesAndNewlines)) }
                if draft != nil && draft?.isValid != true { Text("Enter a valid http or https URL.").font(.caption).foregroundStyle(.orange) }
            } else {
                ShortcutRecorder(title: draft?.title ?? "Click to record…") { draft = .keystroke($0) }.frame(height: 34)
            }
            Spacer()
        }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// NSTextField's field editor consumes arrows before SwiftUI move commands.
/// Handle those commands at the delegate so search and list share one selection.
private struct ActionPickerSearchField: NSViewRepresentable {
    @Binding var query: String
    let move: (Int) -> Void
    let confirm: () -> Void
    let cancel: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.placeholderString = "Search actions, apps, macros…"
        field.isBezeled = false; field.drawsBackground = false; field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.delegate = context.coordinator
        field.setAccessibilityIdentifier("action-picker-search")
        field.setAccessibilityLabel("Search actions, apps, macros")
        DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != query { field.stringValue = query }
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ActionPickerSearchField
        init(_ parent: ActionPickerSearchField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.query = field.stringValue
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            // Leave input-method candidate navigation and confirmation intact.
            guard !textView.hasMarkedText() else { return false }
            switch selector {
            case #selector(NSResponder.moveDown(_:)): parent.move(1)
            case #selector(NSResponder.moveUp(_:)): parent.move(-1)
            case #selector(NSResponder.insertNewline(_:)): parent.confirm()
            case #selector(NSResponder.cancelOperation(_:)): parent.cancel()
            default: return false
            }
            return true
        }
    }
}
