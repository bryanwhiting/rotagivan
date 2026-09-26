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
        // Seed Foundation's path cache before replacing that same application.
        precondition(ExplorerApplicationCatalog.bundleIdentifier(at: chrome) == prefix + ".chrome")
        _ = Bundle(url: chrome)?.bundleIdentifier
        let replacement = try makeApp("Replacement.app", under: root, id: prefix + ".replacement", name: "New identity")
        try manager.moveItem(at: chrome, to: root.appendingPathComponent("Retired.app"))
        try manager.moveItem(at: replacement, to: chrome)
        let replaced = ExplorerApplicationCatalog.application(at: chrome)!
        precondition(replaced.bundleID == prefix + ".replacement" && replaced.name == "New identity",
                     "Same-path replacement must not use cached Bundle metadata")
        precondition(ExplorerApplicationCatalog.bundleIdentifier(at: chrome) == prefix + ".replacement",
                     "Identity-only validation must also reject cached replacement identity")
        let localized = chrome.appendingPathComponent("Contents/Resources/en.lproj", isDirectory: true)
        try manager.createDirectory(at: localized, withIntermediateDirectories: true)
        let localizedInfo = try PropertyListSerialization.data(fromPropertyList: ["CFBundleDisplayName": "Localized identity"], format: .binary, options: 0)
        try localizedInfo.write(to: localized.appendingPathComponent("InfoPlist.strings"))
        precondition(ExplorerApplicationCatalog.application(at: chrome)?.name == "Localized identity")
        precondition(ExplorerApplicationCatalog.bundleIdentifier(at: chrome) == prefix + ".replacement",
                     "Identity validation is independent of display localization")
        let flat = root.appendingPathComponent("Flat.app", isDirectory: true)
        try manager.createDirectory(at: flat, withIntermediateDirectories: true)
        let flatInfo = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": prefix + ".flat"], format: .binary, options: 0)
        try flatInfo.write(to: flat.appendingPathComponent("Info.plist"))
        precondition(ExplorerApplicationCatalog.application(at: flat)?.name == "Flat", "Flat bundles retain filename fallback")
        try Data("invalid plist".utf8).write(to: flat.appendingPathComponent("Info.plist"))
        precondition(ExplorerApplicationCatalog.application(at: flat) == nil)
        precondition(ExplorerApplicationCatalog.bundleIdentifier(at: flat) == nil)
        try Data(repeating: 65, count: 1_048_577).write(to: flat.appendingPathComponent("Info.plist"))
        precondition(ExplorerApplicationCatalog.application(at: flat) == nil, "Oversized metadata must be rejected")
        precondition(ExplorerApplicationCatalog.bundleIdentifier(at: flat) == nil)
        let externalInfo = root.appendingPathComponent("ExternalInfo.plist")
        try flatInfo.write(to: externalInfo)
        try manager.removeItem(at: flat.appendingPathComponent("Info.plist"))
        try manager.createSymbolicLink(at: flat.appendingPathComponent("Info.plist"), withDestinationURL: externalInfo)
        precondition(ExplorerApplicationCatalog.application(at: flat)?.bundleID == prefix + ".flat",
                     "Info.plist symlinks to regular files retain compatibility")
        precondition(ExplorerApplicationCatalog.bundleIdentifier(at: flat) == prefix + ".flat")
        precondition(ExplorerApplicationCatalog.bundleIdentifier(at: URL(string: "https://example.invalid/App.app")!) == nil)
        precondition(ExplorerApplicationCatalog.bundleIdentifier(at: global.appendingPathComponent("Rotagivan.app")) == nil)
        let aliasRoot = root.appendingPathComponent("ExplicitApplicationsAlias", isDirectory: true)
        try manager.createSymbolicLink(at: aliasRoot, withDestinationURL: global)
        precondition(ExplorerApplicationCatalog.scan(roots: [aliasRoot]).contains { $0.bundleID == prefix + ".replacement" },
                     "Explicit application-root symlinks are traversed, unlike arbitrary descendant symlinks")
        print("App picker passed: both roots, nested Chrome apps, safe traversal, duplicate/helper filtering, fuzzy ranking, local resolution, and portable settings.")
    }
}
