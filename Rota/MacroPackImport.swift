import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The one import path for macro packs, shared by the Actions "Add action"
/// menu and the action picker's Macros tab: choose a file (or a built-in
/// pack), merge it into the macro library, confirm what changed and show the
/// pack's notes.
@MainActor enum MacroPackImport {
    /// Packs shipped inside the app bundle; the bundle does not change at runtime.
    static let builtInPacks = MacroPack.builtInPacks()

    static var yamlTypes: [UTType] {
        [UTType.yaml, UTType(filenameExtension: "yaml"), UTType(filenameExtension: "yml")].compactMap { $0 }
    }

    /// Merge and store. Throws without touching settings when the result would be invalid.
    @discardableResult static func apply(_ pack: MacroPack, to store: SettingsStore) throws -> MacroPackImportResult {
        let merged = try store.settings.resolvedHotkeyDictionary.importing(pack)
        store.settings.hotkeyDictionary = merged.macros
        return merged.result
    }

    /// Pick a .yaml/.yml file, import it and confirm. The completion receives
    /// the stored macros from that pack, or nil when cancelled or failed.
    static func chooseAndImport(into store: SettingsStore, completion: @escaping ([NamedHotkey]?) -> Void = { _ in }) {
        let panel = NSOpenPanel()
        panel.title = "Import macro pack"
        panel.message = "Choose a Rota macro pack (.yaml). See docs/macro-packs.md for the format."
        panel.allowedContentTypes = yamlTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { completion(nil); return }
            completion(importPack(at: url, into: store))
        }
    }

    static func importBuiltIn(_ pack: MacroPack.BuiltIn, into store: SettingsStore, completion: @escaping ([NamedHotkey]?) -> Void = { _ in }) {
        completion(importPack(at: pack.url, into: store))
    }

    /// Parse, merge, store and confirm. Errors are shown; nothing is stored.
    static func importPack(at url: URL, into store: SettingsStore) -> [NamedHotkey]? {
        do {
            let pack = try MacroPack.parse(contentsOf: url)
            let result = try apply(pack, to: store)
            present(result)
            let ids = Set(pack.namedHotkeys().map(\.id))
            return store.settings.resolvedHotkeyDictionary.filter { ids.contains($0.id) }
        } catch {
            presentError("Could not import “\(url.lastPathComponent)”", error)
            return nil
        }
    }

    static func present(_ result: MacroPackImportResult) {
        let alert = NSAlert()
        alert.messageText = result.message
        var details: [String] = []
        if let scope = result.pack.scope {
            switch scope {
            case .app(_, let name): details.append("These macros bring \(name) to the front before typing.")
            case .website(let url): details.append("These macros open \(url.absoluteString) before typing, reusing an open tab when Chrome is the default browser.")
            }
        }
        details.append("Find them under Macros › \(result.pack.name) in the actions table and in the action picker's Macros tab.")
        if let notes = result.pack.notes { details.append("Notes from the pack: " + notes) }
        alert.informativeText = details.joined(separator: "\n\n")
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    static func presentError(_ title: String, _ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Write every macro sharing `packName` as one pack file.
    static func export(packName: String, from store: SettingsStore) {
        let macros = store.settings.resolvedHotkeyDictionary.filter { $0.packName == packName }
        let yaml: String
        do { yaml = try MacroPack(name: packName, exporting: macros).yaml() }
        catch { presentError("Could not export the \(packName) pack", error); return }
        let panel = NSSavePanel()
        panel.title = "Export macro pack"
        panel.allowedContentTypes = yamlTypes
        panel.nameFieldStringValue = MacroPack.slug(packName) + ".yaml"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do { try yaml.write(to: url, atomically: true, encoding: .utf8) }
            catch { presentError("Could not write “\(url.lastPathComponent)”", error) }
        }
    }
}

extension MacroPackImport {
    /// Called once at launch so every action picker (settings window and the
    /// HUD's inline editor) can create and import macros.
    static func registerPickerTools() { ActionPickerMacroTools.factory = pickerTools }

    /// Tools backed by the settings store: the shared saved-action editor and
    /// the shared pack import, both persisting before they report back.
    static func pickerTools(store: SettingsStore) -> ActionPickerMacroTools {
        ActionPickerMacroTools(editor: { onSave, onCancel in
            AnyView(NamedHotkeyEditor(entry: NamedHotkey(name: "", shortcut: RecordedShortcut(keyCode: 64, modifiers: 0, keyLabel: "F17")),
                existing: store.settings.resolvedHotkeyDictionary, onSave: { entry in
                    var next = store.settings.resolvedHotkeyDictionary.filter { $0.id != entry.id }
                    next.append(entry)
                    guard next.isValidDictionary else { return }
                    store.settings.hotkeyDictionary = next
                    onSave(entry)
                }, onCancel: onCancel))
        }, importPack: { completion in
            MacroPackImport.chooseAndImport(into: store, completion: completion)
        })
    }
}
