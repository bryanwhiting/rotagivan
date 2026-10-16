import AppKit
import ApplicationServices

struct ChromeRecentTab: Hashable, Sendable {
    let windowIndex: Int
    let tabIndex: Int
    let title: String
    let url: String
    var profileName: String? = nil
    var profileIsEstimated = false
    var id: String { "chrome-tab:\(windowIndex):\(tabIndex):\(url)" }
}

struct LauncherMenuAction: Hashable, Sendable {
    let pid: pid_t
    let indices: [Int]
    let titles: [String]
    var id: String { "menu:\(pid):" + indices.map(String.init).joined(separator: ".") }
}
struct LauncherAction: Identifiable, Hashable, Sendable {
    enum Target: Hashable, Sendable { case app(ExplorerApplication), folder(ExplorerFolder), chromeTab(ChromeRecentTab), rotaSettings, menu(LauncherMenuAction), registered(String) }
    let id: String
    let name: String
    let detail: String
    let target: Target
    var searchEntry: ExplorerApplication {
        if case .app(let app) = target { return app }
        if case .folder(let folder) = target {
            return ExplorerApplication(bundleID: folder.url.path, name: folder.name, url: folder.url)
        }
        return ExplorerApplication(bundleID: id, name: name, url: URL(fileURLWithPath: "/launcher-index/" + id))
    }
    static func apps(_ apps: [ExplorerApplication]) -> [Self] {
        apps.map { Self(id:$0.id,name:$0.name,detail:$0.location,target:.app($0)) }
    }
    static func folders(_ folders: [ExplorerFolder]) -> [Self] {
        folders.map { folder in
            Self(id: "folder:" + folder.id, name: folder.name, detail: folder.location, target: .folder(folder))
        }
    }
    static func chromeTabs(_ tabs: [ChromeRecentTab]) -> [Self] {
        tabs.map { tab in
            Self(id: tab.id, name: "Chrome tab · " + (tab.title.isEmpty ? tab.url : tab.title),
                 detail: "Window \(tab.windowIndex), tab \(tab.tabIndex) · \(tab.url)", target: .chromeTab(tab))
        }
    }
    static func registered(_ records: [VoiceRegisteredAction]) -> [Self] {
        records.filter { $0.enabled && $0.action.kind != .openApp }.map {
            let category = $0.action.kind == .macro ? "Macro" : ($0.action.kind == .openURL ? "Website bookmark" : ($0.appName ?? "Mac action"))
            return Self(id: "registered:" + $0.id, name: $0.title,
                detail: category + " · Return twice to confirm", target: .registered($0.id))
        }
    }
    static var settings: Self {
        Self(id:"rota:settings",name:"Rotagivan settings preferences",detail:"Open this app’s settings",target:.rotaSettings)
    }
    static func query(_ spoken: String) -> String {
        var text = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["please open ", "please launch ", "open ", "launch ", "switch to "] {
            if text.lowercased().hasPrefix(prefix) { text = String(text.dropFirst(prefix.count)); break }
        }
        return text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
    }
    private static let index = LauncherActionSearchIndex()
    static func search(_ text: String, actions: [Self], engine: RustApplicationSearch = .shared) -> [Self] {
        let query = query(text)
        guard !query.isEmpty else { return [] }
        return LauncherUsageOrder.apply(index.search(query, actions: actions, engine: engine), query: query)
    }

}

/// Optional local-only personalization. Identity until the activity feature starts.
enum LauncherUsageOrder {
    private static let lock = NSLock()
    private static var order: (([LauncherAction], String) -> [LauncherAction])?
    static func install(_ value: @escaping ([LauncherAction], String) -> [LauncherAction]) {
        lock.lock(); defer { lock.unlock() }; order = value
    }
    static func apply(_ matches: [LauncherAction], query: String) -> [LauncherAction] {
        lock.lock(); let callback = order; lock.unlock()
        return callback?(matches, query) ?? matches
    }
}

/// Only public AX attributes/actions from the captured frontmost app. No permission
/// prompting, menu opening during discovery, synthetic keys, or private URLs.
enum LauncherMenuCatalog {
    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element,name as CFString,&value) == .success else { return nil }
        return value
    }
    private static func children(_ element: AXUIElement) -> [AXUIElement] { attribute(element,kAXChildrenAttribute) as? [AXUIElement] ?? [] }
    private static func title(_ element: AXUIElement) -> String { attribute(element,kAXTitleAttribute) as? String ?? "" }
    private static func enabled(_ element: AXUIElement) -> Bool { (attribute(element,kAXEnabledAttribute) as? Bool) != false }
    private static func pressable(_ element: AXUIElement) -> Bool {
        var names: CFArray?
        return AXUIElementCopyActionNames(element,&names) == .success && ((names as? [String]) ?? []).contains(kAXPressAction)
    }
    static func scan(pid: pid_t) -> [LauncherAction] {
        guard AXIsProcessTrusted(), pid != ProcessInfo.processInfo.processIdentifier else { return [] }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app,0.15)
        guard let menu = attribute(app,kAXMenuBarAttribute), CFGetTypeID(menu) == AXUIElementGetTypeID() else { return [] }
        var result: [LauncherAction] = []
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        func walk(_ parent: AXUIElement, indices: [Int], titles: [String], depth: Int) {
            guard depth < 5, result.count < 200, ProcessInfo.processInfo.systemUptime < deadline else { return }
            for (index,child) in children(parent).prefix(100).enumerated() {
                guard result.count < 200, ProcessInfo.processInfo.systemUptime < deadline else { break }
                let name = title(child), path = indices + [index], labels = titles + [name]
                let readable = labels.filter { !$0.isEmpty }
                if !name.isEmpty, enabled(child), pressable(child) {
                    let action = LauncherMenuAction(pid:pid,indices:path,titles:labels)
                    result.append(LauncherAction(id:action.id,name:readable.joined(separator:" → "),
                        detail:"App menu · Return twice to confirm",target:.menu(action)))
                }
                walk(child,indices:path,titles:labels,depth:depth+1)
            }
        }
        walk(unsafeBitCast(menu,to:AXUIElement.self),indices:[],titles:[],depth:0)
        return result
    }
    static func execute(_ action: LauncherMenuAction) -> String? {
        guard AXIsProcessTrusted() else { return "Accessibility access is unavailable. No menu action ran." }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == action.pid else { return "The active app changed. Reopen the launcher and choose again." }
        let app = AXUIElementCreateApplication(action.pid)
        AXUIElementSetMessagingTimeout(app,0.15)
        guard let menu = attribute(app,kAXMenuBarAttribute), CFGetTypeID(menu) == AXUIElementGetTypeID() else { return "This app does not expose its menu." }
        var element = unsafeBitCast(menu,to:AXUIElement.self)
        guard !action.indices.isEmpty, action.indices.count == action.titles.count else { return "Invalid menu selection." }
        for (offset,index) in action.indices.enumerated() {
            let items = children(element)
            guard items.indices.contains(index), title(items[index]) == action.titles[offset], enabled(items[index]) else { return "The selected menu changed or is unavailable. Nothing ran." }
            element = items[index]
        }
        guard pressable(element), AXUIElementPerformAction(element,kAXPressAction as CFString) == .success else { return "macOS could not activate this menu item." }
        return nil
    }
}

/// Cache URL identities and lookup tables alongside Rust's normalized index.
/// A query does not reconstruct hundreds of URL objects as words arrive.
private final class LauncherActionSearchIndex: @unchecked Sendable {
    private let lock = NSLock()
    private var actions: [LauncherAction] = []
    private var entries: [ExplorerApplication] = []
    private var byID: [String: LauncherAction] = [:]
    private var engine: RustApplicationSearch?
    func search(_ query: String, actions: [LauncherAction], engine: RustApplicationSearch) -> [LauncherAction] {
        lock.lock(); defer { lock.unlock() }
        if self.engine !== engine || self.actions != actions {
            self.engine = engine; self.actions = actions
            entries = actions.map(\.searchEntry)
            byID = Dictionary(zip(entries, actions).map { ($0.0.id, $0.1) }, uniquingKeysWith: { first, _ in first })
        }
        return engine.search(query, applications: entries).compactMap { byID[$0.id] }
    }
}
