import AppKit

@main struct ExplorerApplicationCatalogTests {
    static func main() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("rotagivan-catalog-tests-\(UUID().uuidString)", isDirectory: true)
        let global = root.appendingPathComponent("Applications", isDirectory: true)
        let user = root.appendingPathComponent("UserApplications", isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        func makeApp(_ relative: String, under parent: URL, id: String, name: String) throws -> URL {
            let url = parent.appendingPathComponent(relative, isDirectory: true)
            let contents = url.appendingPathComponent("Contents", isDirectory: true)
            try manager.createDirectory(at: contents, withIntermediateDirectories: true)
            let info: [String: Any] = ["CFBundleIdentifier": id, "CFBundleName": name,
                "CFBundleDisplayName": name, "CFBundlePackageType": "APPL", "CFBundleExecutable": "Fixture"]
            let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try data.write(to: contents.appendingPathComponent("Info.plist"))
            return url
        }
        let prefix = "local.rotagivan.test.\(UUID().uuidString)"
        let chrome = try makeApp("Google Chrome.app", under: global, id: prefix + ".chrome", name: "Google Chrome")
        let gmail = try makeApp("Chrome Apps.localized/Gmail.app", under: user, id: prefix + ".gmail", name: "Gmail")
        _ = try makeApp("Developer/Visual Studio Code.app", under: global, id: prefix + ".code", name: "Visual Studio Code")
        _ = try makeApp("Resume.app", under: user, id: prefix + ".resume", name: "Résumé")
        _ = try makeApp("Chrome.app", under: user, id: prefix + ".otherChrome", name: "Chrome")
        _ = try makeApp(".Hidden.app", under: user, id: prefix + ".hidden", name: "Hidden")
        _ = try makeApp("Rotagivan.app", under: global, id: "local.rotagivan", name: "Rotagivan")
        _ = try makeApp("Contents/Helpers/Helper.app", under: chrome, id: prefix + ".helper", name: "Helper")
        try manager.createSymbolicLink(at: user.appendingPathComponent("loop"), withDestinationURL: user)
        try manager.createSymbolicLink(at: user.appendingPathComponent("Alias.app"), withDestinationURL: chrome)
        let apps = ExplorerApplicationCatalog.scan(roots: [global, user, global, root.appendingPathComponent("Missing")])
        precondition(apps.count == 5, "Find both roots and nested Chrome apps, excluding helpers, hidden apps, duplicates, and Rota")
        precondition(apps.contains { $0.url == gmail })
        precondition(ExplorerApplicationCatalog.search("gchr", in: apps).first?.name == "Google Chrome")
        precondition(ExplorerApplicationCatalog.search("GOO chr", in: apps).first?.name == "Google Chrome")
        precondition(ExplorerApplicationCatalog.search("vsc", in: apps).first?.name == "Visual Studio Code")
        precondition(ExplorerApplicationCatalog.search("resume", in: apps).first?.name == "Résumé")
        precondition(ExplorerApplicationCatalog.search("chrome", in: apps).first?.name == "Chrome", "Exact names rank above partial matches")
        precondition(ExplorerApplicationCatalog.search(prefix + ".gmail", in: apps).first?.url == gmail)
        precondition(ExplorerApplicationCatalog.search("unlikelyxyzxyz", in: apps).isEmpty)
        precondition(ExplorerApplicationCatalog.search(" \n ", in: apps).count == apps.count)
        let suite = "Rotagivan.CatalogTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let selected = ExplorerApplicationCatalog.application(at: gmail)!
        ExplorerApplicationCatalog.remember(selected, defaults: defaults)
        precondition(ExplorerApplicationCatalog.applicationURL(for: selected.bundleID, defaults: defaults) == gmail,
                     "Unregistered Chrome apps must resolve from their selected local path")
        let favorite = AppExplorerFavorite(direction: .left, bundleID: selected.bundleID, name: selected.name)
        let encoded = String(decoding: try JSONEncoder().encode(AppExplorerSettings(favorites: [favorite])), as: UTF8.self)
        precondition(!encoded.contains(root.path), "Machine-specific paths never enter exported/synced settings")
        defaults.set([selected.bundleID: chrome.path], forKey: "appExplorer.localApplicationPaths")
        precondition(ExplorerApplicationCatalog.applicationURL(for: selected.bundleID, defaults: defaults) == nil,
                     "Do not launch a different bundle found at a stale path")
        defaults.set([selected.bundleID: root.appendingPathComponent("Moved.app").path], forKey: "appExplorer.localApplicationPaths")
        precondition(ExplorerApplicationCatalog.applicationURL(for: selected.bundleID, defaults: defaults) == nil)
        print("App picker passed: both roots, nested Chrome apps, safe traversal, duplicate/helper filtering, fuzzy ranking, local resolution, and portable settings.")
    }
}
