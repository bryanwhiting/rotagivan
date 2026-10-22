import Foundation
import ConfigurationYAML

/// Human-writable keyboard chords for macro packs: modifiers joined with "+"
/// to one key name, for example "cmd+shift+k" or "⌘⇧K". Key codes are the US
/// layout's virtual key codes, matching what the shortcut recorder captures.
enum KeyChord {
    struct Key: Equatable {
        let code: UInt16
        /// The label the shortcut recorder would produce for the same key.
        let label: String
        /// The spelling used when a pack is exported.
        let name: String
    }

    static let modifierAliases: [String: UInt64] = [
        "cmd": 1 << 20, "command": 1 << 20, "⌘": 1 << 20,
        "shift": 1 << 17, "⇧": 1 << 17,
        "opt": 1 << 19, "option": 1 << 19, "alt": 1 << 19, "⌥": 1 << 19,
        "ctrl": 1 << 18, "control": 1 << 18, "⌃": 1 << 18
    ]

    /// Canonical key names in the order used for export, plus aliases.
    static let keys: [Key] = {
        var result: [Key] = []
        let letters: [(Character, UInt16)] = [("a", 0), ("s", 1), ("d", 2), ("f", 3), ("h", 4), ("g", 5), ("z", 6), ("x", 7), ("c", 8), ("v", 9),
            ("b", 11), ("q", 12), ("w", 13), ("e", 14), ("r", 15), ("y", 16), ("t", 17), ("o", 31), ("u", 32), ("i", 34), ("p", 35),
            ("l", 37), ("j", 38), ("k", 40), ("n", 45), ("m", 46)]
        for (letter, code) in letters { result.append(Key(code: code, label: String(letter).uppercased(), name: String(letter))) }
        let digits: [(Character, UInt16)] = [("1", 18), ("2", 19), ("3", 20), ("4", 21), ("5", 23), ("6", 22), ("7", 26), ("8", 28), ("9", 25), ("0", 29)]
        for (digit, code) in digits { result.append(Key(code: code, label: String(digit), name: String(digit))) }
        let functionCodes: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
        for (index, code) in functionCodes.enumerated() { result.append(Key(code: code, label: "F\(index + 1)", name: "f\(index + 1)")) }
        result += [
            Key(code: 36, label: "Return", name: "return"), Key(code: 76, label: "Enter", name: "enter"),
            Key(code: 48, label: "Tab", name: "tab"), Key(code: 49, label: "Space", name: "space"),
            Key(code: 53, label: "Escape", name: "esc"), Key(code: 51, label: "Delete", name: "delete"),
            Key(code: 117, label: "Forward Delete", name: "forwarddelete"),
            Key(code: 123, label: "←", name: "left"), Key(code: 124, label: "→", name: "right"),
            Key(code: 126, label: "↑", name: "up"), Key(code: 125, label: "↓", name: "down"),
            Key(code: 115, label: "Home", name: "home"), Key(code: 119, label: "End", name: "end"),
            Key(code: 116, label: "Page Up", name: "pageup"), Key(code: 121, label: "Page Down", name: "pagedown"),
            Key(code: 43, label: ",", name: ","), Key(code: 47, label: ".", name: "."), Key(code: 44, label: "/", name: "/"),
            Key(code: 41, label: ";", name: ";"), Key(code: 39, label: "'", name: "'"), Key(code: 33, label: "[", name: "["),
            Key(code: 30, label: "]", name: "]"), Key(code: 42, label: "\\", name: "\\"), Key(code: 27, label: "-", name: "-"),
            Key(code: 24, label: "=", name: "="), Key(code: 50, label: "`", name: "`")
        ]
        return result
    }()

    static let keyAliases: [String: Key] = {
        var table: [String: Key] = [:]
        for key in keys { table[key.name] = key }
        func alias(_ names: [String], _ name: String) { for value in names { table[value] = table[name] } }
        alias(["escape"], "esc"); alias(["backspace"], "delete"); alias(["fwddelete", "del"], "forwarddelete")
        alias(["spacebar"], "space"); alias(["comma"], ","); alias(["period", "dot"], "."); alias(["slash"], "/")
        alias(["semicolon"], ";"); alias(["quote", "apostrophe"], "'"); alias(["backslash"], "\\")
        alias(["minus", "hyphen"], "-"); alias(["equals", "equal", "plus"], "="); alias(["backtick", "grave"], "`")
        alias(["leftbracket"], "["); alias(["rightbracket"], "]")
        alias(["arrowleft", "leftarrow", "←"], "left"); alias(["arrowright", "rightarrow", "→"], "right")
        alias(["arrowup", "uparrow", "↑"], "up"); alias(["arrowdown", "downarrow", "↓"], "down")
        alias(["pgup"], "pageup"); alias(["pgdn", "pgdown"], "pagedown")
        return table
    }()

    static func parse(_ text: String) -> RecordedShortcut? { try? parseStrictly(text) }

    /// A chord with a specific reason when it is malformed.
    static func parseStrictly(_ text: String) throws -> RecordedShortcut {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MacroPackError("the chord is empty") }
        var tokens = trimmed.split(separator: "+", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        }
        // "cmd++" spells the + key ambiguously; packs write it as "shift+=".
        if tokens.contains("") { throw MacroPackError("“\(trimmed)” has an empty part; join modifiers and one key with “+”, such as cmd+shift+k") }
        // Glued symbol modifiers ("⌘⇧K") count as separate parts.
        if tokens.count == 1 {
            var glued: [String] = []
            var rest = Substring(tokens[0])
            while let first = rest.first, ["⌘", "⇧", "⌥", "⌃"].contains(String(first)), rest.count > 1 {
                glued.append(String(first)); rest = rest.dropFirst()
            }
            tokens = glued + [String(rest)]
        }
        var modifiers: UInt64 = 0
        for token in tokens.dropLast() {
            guard let flag = modifierAliases[token] else {
                throw MacroPackError(keyAliases[token] != nil
                    ? "“\(trimmed)” names the key “\(token)” before its modifiers; put the key last"
                    : "unknown modifier “\(token)” in “\(trimmed)”; use cmd, shift, opt or ctrl")
            }
            guard modifiers & flag == 0 else { throw MacroPackError("“\(trimmed)” repeats the modifier “\(token)”") }
            modifiers |= flag
        }
        let last = tokens[tokens.count - 1]
        guard modifierAliases[last] == nil else { throw MacroPackError("“\(trimmed)” has no key after its modifiers") }
        guard let key = keyAliases[last] else { throw MacroPackError("unknown key “\(last)” in “\(trimmed)”") }
        return RecordedShortcut(keyCode: key.code, modifiers: modifiers, keyLabel: key.label)
    }

    /// The canonical pack spelling of a recorded shortcut, or nil for keys
    /// outside the pack vocabulary.
    static func format(_ shortcut: RecordedShortcut) -> String? {
        guard shortcut.isPhysicalShortcut, let key = keys.first(where: { $0.code == shortcut.keyCode }) else { return nil }
        let names: [(UInt64, String)] = [(1 << 18, "ctrl"), (1 << 19, "opt"), (1 << 17, "shift"), (1 << 20, "cmd")]
        return (names.compactMap { shortcut.modifiers & $0.0 != 0 ? $0.1 : nil } + [key.name]).joined(separator: "+")
    }
}

struct MacroPackError: LocalizedError, Equatable {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// A YAML file of macros for one app or website. See docs/macro-packs.md.
struct MacroPack: Equatable {
    static let format = "rotagivan-macro-pack/1"
    static let maximumMacros = 500

    struct Macro: Equatable {
        var name: String
        var steps: [RecordedShortcut]
        var delay: Int? = nil
    }

    var name: String
    var appBundleID: String? = nil
    var appName: String? = nil
    var website: String? = nil
    var notes: String? = nil
    var macros: [Macro]

    init(name: String, appBundleID: String? = nil, appName: String? = nil, website: String? = nil, notes: String? = nil, macros: [Macro]) {
        self.name = name; self.appBundleID = appBundleID; self.appName = appName
        self.website = website; self.notes = notes; self.macros = macros
    }

    var scope: MacroScope? {
        if let appBundleID { return .app(bundleID: appBundleID, name: appName ?? name) }
        if let website, let url = NamedHotkey.websiteURL(website) { return .website(url) }
        return nil
    }

    // MARK: Parsing

    static func parse(contentsOf url: URL) throws -> MacroPack {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw MacroPackError("Could not read “\(url.lastPathComponent)” as UTF-8 text.")
        }
        return try parse(text)
    }

    static func parse(_ yaml: String) throws -> MacroPack {
        let root: PackValue
        do { root = try ConfigurationYAML.decode(PackValue.self, from: yaml) }
        catch { throw MacroPackError("This isn’t valid YAML: \(error.localizedDescription)") }
        guard case .object(let fields) = root else { throw MacroPackError("A macro pack is a YAML mapping with format, name and macros.") }
        try expect(fields, allowed: ["format", "name", "app", "appName", "website", "notes", "macros"], at: "the pack")
        guard fields["format"]?.string == format else {
            throw MacroPackError("Missing or unsupported format. The first line should be: format: \(format)")
        }
        guard let name = fields["name"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            throw MacroPackError("The pack needs a name.")
        }
        guard name.count <= 120, !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw MacroPackError("The pack name must be at most 120 characters.")
        }
        var pack = MacroPack(name: name, macros: [])
        if let app = fields["app"] {
            guard let bundleID = app.string?.trimmingCharacters(in: .whitespacesAndNewlines), MacroStep.app(bundleID: bundleID, name: "App").isValid else {
                throw MacroPackError("app must be an application bundle ID such as com.tinyspeck.slackmacgap.")
            }
            pack.appBundleID = bundleID
        }
        if let website = fields["website"] {
            guard pack.appBundleID == nil else { throw MacroPackError("A pack is scoped to an app or a website, not both.") }
            guard let text = website.string?.trimmingCharacters(in: .whitespacesAndNewlines), text.count <= 512,
                  NamedHotkey.websiteURL(text) != nil else {
                throw MacroPackError("website must be an http(s) URL with a host, such as https://mail.google.com.")
            }
            pack.website = text
        }
        if let appName = fields["appName"] {
            guard pack.appBundleID != nil else { throw MacroPackError("appName only applies with app.") }
            guard let text = appName.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, text.count <= 128,
                  !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw MacroPackError("appName must be 1–128 characters.")
            }
            pack.appName = text
        }
        if let notes = fields["notes"] {
            guard let text = notes.string?.trimmingCharacters(in: .whitespacesAndNewlines), text.count <= 2000 else {
                throw MacroPackError("notes must be text of at most 2000 characters.")
            }
            pack.notes = text.isEmpty ? nil : text
        }
        guard case .array(let entries)? = fields["macros"], !entries.isEmpty else {
            throw MacroPackError("macros must be a list with at least one macro.")
        }
        guard entries.count <= maximumMacros else { throw MacroPackError("A pack holds at most \(maximumMacros) macros.") }
        var seen = Set<String>()
        for (index, entry) in entries.enumerated() {
            let macro = try parseMacro(entry, index: index)
            guard seen.insert(macroID(pack: name, macro: macro.name)).inserted else {
                throw MacroPackError("Macro \(index + 1) “\(macro.name)” repeats another macro's name; names must be unique within a pack.")
            }
            pack.macros.append(macro)
        }
        return pack
    }

    private static func parseMacro(_ value: PackValue, index: Int) throws -> Macro {
        let position = "Macro \(index + 1)"
        guard case .object(let fields) = value else { throw MacroPackError("\(position) must be a mapping with name and keys or steps.") }
        try expect(fields, allowed: ["name", "keys", "steps", "delay"], at: position)
        guard let name = fields["name"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            throw MacroPackError("\(position) needs a name.")
        }
        guard name.count <= 120, !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw MacroPackError("\(position) “\(name)”: the name must be at most 120 characters.")
        }
        let label = "\(position) “\(name)”"
        var chords: [String] = []
        switch (fields["keys"], fields["steps"]) {
        case (nil, nil): throw MacroPackError("\(label) needs keys (one chord) or steps (a list of chords).")
        case (.some, .some): throw MacroPackError("\(label) has both keys and steps; use one.")
        case (.some(let keys), nil):
            guard let chord = keys.string else { throw MacroPackError("\(label): keys must be one chord such as cmd+k.") }
            chords = [chord]
        case (nil, .some(let steps)):
            guard case .array(let list) = steps, !list.isEmpty else { throw MacroPackError("\(label): steps must be a list of chords.") }
            guard list.count <= 32 else { throw MacroPackError("\(label) has \(list.count) steps; the limit is 32.") }
            for (stepIndex, step) in list.enumerated() {
                guard let chord = step.string else { throw MacroPackError("\(label) step \(stepIndex + 1) must be a chord such as cmd+k.") }
                chords.append(chord)
            }
        }
        var shortcuts: [RecordedShortcut] = []
        for (stepIndex, chord) in chords.enumerated() {
            do { shortcuts.append(try KeyChord.parseStrictly(chord)) }
            catch let error as MacroPackError {
                let step = chords.count == 1 ? "" : " step \(stepIndex + 1)"
                throw MacroPackError("\(label)\(step): \(error.errorDescription ?? "invalid chord")")
            }
        }
        var delay: Int?
        if let value = fields["delay"] {
            guard let number = value.number, number.rounded() == number, (0...2000).contains(number) else {
                throw MacroPackError("\(label): delay must be a whole number of milliseconds from 0 to 2000.")
            }
            delay = Int(number)
        }
        return Macro(name: name, steps: shortcuts, delay: delay)
    }

    private static func expect(_ fields: [String: PackValue], allowed: Set<String>, at position: String) throws {
        if let unknown = fields.keys.sorted().first(where: { !allowed.contains($0) }) {
            throw MacroPackError("Unknown key “\(unknown)” in \(position). Allowed: \(allowed.sorted().joined(separator: ", ")).")
        }
    }

    // MARK: Identity

    /// Lowercase ASCII letters and digits separated by single dashes.
    static func slug(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        var result = ""
        var pendingDash = false
        for scalar in folded.unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                if pendingDash, !result.isEmpty { result.append("-") }
                pendingDash = false
                result.unicodeScalars.append(scalar)
            } else { pendingDash = true }
        }
        return result.isEmpty ? "macro" : result
    }

    /// Deterministic, so re-importing a pack updates its macros in place.
    static func macroID(pack: String, macro: String) -> String {
        "pack:" + slug(pack).prefix(40) + ":" + slug(macro).prefix(80)
    }

    func namedHotkeys() -> [NamedHotkey] {
        macros.map { macro in
            var entry = NamedHotkey(id: Self.macroID(pack: name, macro: macro.name), name: macro.name, shortcut: macro.steps[0])
            // Always a sequence: single-chord macros from different packs may
            // share a chord, which the legacy first-step uniqueness rule forbids.
            entry.sequence = macro.steps.map(MacroStep.key)
            entry.stepDelayMilliseconds = macro.delay
            entry.packName = name
            entry.appBundleID = appBundleID
            entry.appName = appBundleID == nil ? nil : appName ?? name
            entry.website = website
            return entry
        }
    }

    // MARK: Export

    /// A pack rebuilt from saved macros, for export. Every macro must consist of
    /// keystrokes in the pack vocabulary; open-app steps have no pack spelling.
    init(name: String, exporting entries: [NamedHotkey]) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 120 else { throw MacroPackError("A pack needs a name of at most 120 characters.") }
        guard !entries.isEmpty, entries.count <= Self.maximumMacros else { throw MacroPackError("A pack holds 1–\(Self.maximumMacros) macros.") }
        var macros: [Macro] = []
        for entry in entries {
            var steps: [RecordedShortcut] = []
            for step in entry.resolvedSequence {
                guard step.kind == .keystroke, let shortcut = step.shortcut else {
                    throw MacroPackError("“\(entry.name)” opens an app; packs hold keystroke-only macros.")
                }
                guard KeyChord.format(shortcut) != nil else {
                    throw MacroPackError("“\(entry.name)” uses a key (\(shortcut.readableCombination)) that has no pack spelling.")
                }
                steps.append(shortcut)
            }
            macros.append(Macro(name: entry.name, steps: steps, delay: entry.stepDelayMilliseconds))
        }
        guard Set(macros.map { Self.macroID(pack: trimmed, macro: $0.name) }).count == macros.count else {
            throw MacroPackError("Two macros would share a name in the pack; rename one first.")
        }
        self.name = trimmed
        self.macros = macros
        let scoped = entries.first
        appBundleID = scoped?.appBundleID
        appName = scoped?.appBundleID == nil ? nil : scoped?.appName
        website = scoped?.appBundleID == nil ? scoped?.website : nil
    }

    private struct File: Encodable {
        struct Entry: Encodable { var name: String; var keys: String?; var steps: [String]?; var delay: Int? }
        var format = MacroPack.format
        var name: String
        var app: String?
        var appName: String?
        var website: String?
        var notes: String?
        var macros: [Entry]
    }

    func yaml() throws -> String {
        let entries = try macros.map { macro -> File.Entry in
            let chords = try macro.steps.map { step -> String in
                guard let chord = KeyChord.format(step) else { throw MacroPackError("“\(macro.name)” uses a key with no pack spelling.") }
                return chord
            }
            return File.Entry(name: macro.name, keys: chords.count == 1 ? chords[0] : nil, steps: chords.count == 1 ? nil : chords, delay: macro.delay)
        }
        let file = File(name: name, app: appBundleID, appName: appName, website: website, notes: notes, macros: entries)
        let body = try ConfigurationYAML.encode(file)
        let round = try Self.parse(body)
        guard round.macros == macros else { throw MacroPackError("The exported pack did not round-trip.") }
        return "# Rotagivan macro pack · import from Settings → Actions → Add action → Import macro pack…\n" + body
    }

    // MARK: Built-in packs

    struct BuiltIn: Identifiable, Equatable {
        let name: String
        let url: URL
        var id: String { url.path }
    }

    static func builtInPackDirectory(bundle: Bundle = .main) -> URL? {
        bundle.resourceURL?.appendingPathComponent("MacroPacks", isDirectory: true)
    }

    /// Packs shipped in Contents/Resources/MacroPacks, by display name. Files
    /// that fail to parse are skipped so one bad pack never hides the rest.
    static func builtInPacks(directory: URL? = builtInPackDirectory()) -> [BuiltIn] {
        guard let directory, let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { ["yaml", "yml"].contains($0.pathExtension.lowercased()) }
            .compactMap { url in (try? parse(contentsOf: url)).map { BuiltIn(name: $0.name, url: url) } }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

struct MacroPackImportResult: Equatable {
    let pack: MacroPack
    let added: Int
    let updated: Int
    var message: String {
        let total = added + updated
        return "Imported \(total) macro\(total == 1 ? "" : "s") from \(pack.name) (\(updated) updated)"
    }
}

extension Array where Element == NamedHotkey {
    /// Merge a pack into the macro library. Macros with the same deterministic
    /// id are replaced in place and keep their assigned global hotkey; new
    /// macros are appended.
    func importing(_ pack: MacroPack) throws -> (macros: [NamedHotkey], result: MacroPackImportResult) {
        var library = self
        var added = 0, updated = 0
        for var macro in pack.namedHotkeys() {
            if let index = library.firstIndex(where: { $0.id == macro.id }) {
                macro.activationShortcut = library[index].activationShortcut
                library[index] = macro
                updated += 1
            } else {
                library.append(macro)
                added += 1
            }
        }
        guard library.count <= 500 else {
            throw MacroPackError("Importing \(pack.name) would exceed the limit of 500 macros. Remove some macros first.")
        }
        guard library.isValidDictionary else {
            throw MacroPackError("Importing \(pack.name) would leave the macro library invalid.")
        }
        return (library, MacroPackImportResult(pack: pack, added: added, updated: updated))
    }
}

/// Data-only view of the YAML document, so errors can name the macro and chord.
private indirect enum PackValue: Decodable {
    case object([String: Self]), array([Self]), number(Double), string(String), bool(Bool), null

    init(from decoder: Decoder) throws {
        let box = try decoder.singleValueContainer()
        if box.decodeNil() { self = .null }
        else if let object = try? box.decode([String: Self].self) { self = .object(object) }
        else if let array = try? box.decode([Self].self) { self = .array(array) }
        else if let bool = try? box.decode(Bool.self) { self = .bool(bool) }
        else if let number = try? box.decode(Double.self) { self = .number(number) }
        else { self = .string(try box.decode(String.self)) }
    }

    /// Scalars that YAML typed as numbers or booleans still read as their text,
    /// so a macro can be named "1" or a key spelled "0".
    var string: String? {
        switch self {
        case .string(let text): return text
        case .number(let number): return number.rounded() == number ? String(Int(number)) : String(number)
        case .bool(let flag): return flag ? "true" : "false"
        default: return nil
        }
    }
    var number: Double? {
        switch self {
        case .number(let number): return number
        case .string(let text): return Double(text)
        default: return nil
        }
    }
}
