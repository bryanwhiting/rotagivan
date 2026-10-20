import Foundation

@main struct MCPTests {
    static func json(_ text: String?) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data((text ?? "").utf8))) as? [String: Any] ?? [:]
    }
    static func line(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }

    @MainActor static func main() throws {
        FileHandle.standardError.write(Data("p\n".utf8)); try protocolTests()
        FileHandle.standardError.write(Data("t\n".utf8)); try toolTests()
        FileHandle.standardError.write(Data("b\n".utf8)); try bridgeTests()
        print("MCPTests passed")
    }

    @MainActor static func protocolTests() throws {
        var forwarded: [(String, [String: Any])] = []
        let server = MCPStdioServer(version: "9.9.9") { tool, arguments in
            forwarded.append((tool, arguments))
            return tool == "list_bookmarks" ? (true, "{\"bookmarks\":[]}") : (false, "nope")
        }
        let initialize = json(server.handle(line: line(["jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "t", "version": "1"]]])))
        let result = initialize["result"] as! [String: Any]
        precondition(initialize["id"] as? Int == 1 && result["protocolVersion"] as? String == "2025-06-18")
        precondition((result["serverInfo"] as? [String: Any])?["version"] as? String == "9.9.9")
        precondition((result["capabilities"] as? [String: Any])?["tools"] != nil)
        let future = json(server.handle(line: line(["jsonrpc": "2.0", "id": "a", "method": "initialize", "params": ["protocolVersion": "2099-01-01"]])))
        precondition((future["result"] as? [String: Any])?["protocolVersion"] as? String == MCPStdioServer.protocolVersion && future["id"] as? String == "a")
        precondition(server.handle(line: line(["jsonrpc": "2.0", "method": "notifications/initialized"])) == nil, "Notifications get no reply")
        precondition(server.handle(line: line(["jsonrpc": "2.0", "id": 5, "result": [:]])) == nil, "Client responses get no reply")
        precondition((json(server.handle(line: line(["jsonrpc": "2.0", "id": 2, "method": "ping"])))["result"] as? [String: Any])?.isEmpty == true)

        let list = json(server.handle(line: line(["jsonrpc": "2.0", "id": 3, "method": "tools/list"])))
        let tools = (list["result"] as! [String: Any])["tools"] as! [[String: Any]]
        let names = Set(tools.compactMap { $0["name"] as? String })
        precondition(names == ["get_settings_summary", "list_bookmarks", "add_bookmarks", "remove_bookmark", "list_actions",
                               "set_action_keywords", "list_huds", "set_hud_tile", "clear_hud_tile", "list_macros"])
        precondition(tools.allSatisfy { ($0["inputSchema"] as? [String: Any])?["type"] as? String == "object" && $0["description"] is String })
        precondition(!names.contains { $0.contains("run") || $0.contains("key") && $0 != "set_action_keywords" }, "No tool executes actions")

        let call = json(server.handle(line: line(["jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": ["name": "list_bookmarks", "arguments": [:]]])))
        let callResult = call["result"] as! [String: Any]
        precondition(callResult["isError"] as? Bool == false && forwarded.last?.0 == "list_bookmarks")
        precondition(((callResult["content"] as? [[String: Any]])?.first?["text"] as? String)?.contains("bookmarks") == true)
        let failing = json(server.handle(line: line(["jsonrpc": "2.0", "id": 6, "method": "tools/call", "params": ["name": "list_huds"]])))
        precondition((failing["result"] as? [String: Any])?["isError"] as? Bool == true, "Tool failures are results, not protocol errors")
        let count = forwarded.count
        let unknown = json(server.handle(line: line(["jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": ["name": "send_keys"]])))
        precondition((unknown["error"] as? [String: Any])?["code"] as? Int == -32602 && forwarded.count == count, "Unknown tools are never forwarded")
        let badArguments = json(server.handle(line: line(["jsonrpc": "2.0", "id": 8, "method": "tools/call", "params": ["name": "list_huds", "arguments": [1]]])))
        precondition((badArguments["error"] as? [String: Any])?["code"] as? Int == -32602)
        precondition((json(server.handle(line: line(["jsonrpc": "2.0", "id": 9, "method": "resources/list"])))["error"] as? [String: Any])?["code"] as? Int == -32601)
        precondition((json(server.handle(line: Data("{not json".utf8)))["error"] as? [String: Any])?["code"] as? Int == -32700)
        precondition((json(server.handle(line: Data("[{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}]".utf8)))["error"] as? [String: Any])?["code"] as? Int == -32600)
        let huge = Data(repeating: 32, count: MCPBridgeEndpoint.maximumLineBytes + 1)
        precondition((json(server.handle(line: huge))["error"] as? [String: Any])?["code"] as? Int == -32600)
        precondition(MCPBridgeEndpoint.claudeCodeCommand == "claude mcp add rotagivan -- /Applications/Rotagivan.app/Contents/MacOS/rotagivan-mcp")
        precondition(json(MCPBridgeEndpoint.jsonConfiguration)["mcpServers"] != nil, "The JSON snippet parses")
    }

    @MainActor static func toolTests() throws {
        let tools = MCPSettingsTools(applications: [ExplorerApplication(bundleID: "com.apple.Notes", name: "Notes", url: URL(fileURLWithPath: "/System/Applications/Notes.app"))])
        var settings = StoredSettings()
        func call(_ name: String, _ arguments: [String: Any] = [:]) throws -> [String: Any] {
            let outcome = try tools.call(name, arguments: arguments, settings: &settings)
            let text = MCPSettingsTools.render(outcome.result)
            return json(text)
        }
        func fails(_ name: String, _ arguments: [String: Any], _ fragment: String) {
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            let before = try! encoder.encode(settings)
            do {
                _ = try tools.call(name, arguments: arguments, settings: &settings)
                preconditionFailure("\(name) should fail with \(fragment)")
            } catch let error as MCPToolError {
                precondition(error.message.contains(fragment), "\(name): \(error.message)")
            } catch { preconditionFailure("unexpected error") }
            precondition(try! encoder.encode(settings) == before, "Failed calls leave settings unchanged")
        }

        // Bookmarks
        let added = try call("add_bookmarks", ["bookmarks": [
            ["url": "example.com/docs", "name": "Docs", "browser": "chrome"],
            ["url": "https://www.swift.org"],
            ["url": "https://example.com/docs"],
            ["url": "file:///etc/passwd"],
            ["url": "https://user:secret@example.com"],
            ["url": "https://example.org", "browser": "firefox"],
            "not an object"
        ]])
        let addedRows = added["added"] as! [[String: Any]]
        precondition(addedRows.count == 2 && (added["duplicates"] as! [String]) == ["https://example.com/docs"])
        precondition((added["rejected"] as! [[String: Any]]).count == 4)
        precondition(settings.resolvedWebsiteBookmarks.count == 2)
        let docs = settings.resolvedWebsiteBookmarks[0]
        precondition(docs.url == "https://example.com/docs" && docs.name == "Docs" && docs.targetBrowserBundleID == "com.google.Chrome")
        precondition(settings.resolvedWebsiteBookmarks[1].name == "swift.org" && settings.resolvedWebsiteBookmarks[1].targetBrowserBundleID == nil)
        let listed = try call("list_bookmarks")["bookmarks"] as! [[String: Any]]
        precondition(listed.count == 2 && listed[0]["browser"] as? String == "chrome" && listed[1]["browser"] as? String == "default")
        let docsActionID = listed[0]["action_id"] as! String
        precondition(docsActionID == VoiceRegisteredAction.id(for: docs))
        fails("add_bookmarks", ["bookmarks": []], "non-empty")
        fails("add_bookmarks", ["bookmarks": Array(repeating: ["url": "https://a.example"], count: 201)], "at most 200")
        fails("add_bookmarks", ["bookmarks": [["url": "https://a.example"]], "extra": 1], "Unknown argument")
        let rejectedOnly = try tools.call("add_bookmarks", arguments: ["bookmarks": [["url": "javascript:alert(1)"]]], settings: &settings)
        precondition(!rejectedOnly.changed)
        let summary = try call("get_settings_summary")
        precondition(summary["website_bookmarks"] as? Int == 2 && summary["huds"] as? Int == 1)
        precondition(!MCPSettingsTools.render(summary).lowercased().contains("key\":"), "Summary carries counts, not secrets")

        // Actions and voice keywords
        let websites = try call("list_actions", ["group": "Websites"])
        let websiteRows = websites["actions"] as! [[String: Any]]
        precondition(websiteRows.contains { $0["id"] as? String == docsActionID && $0["name"] as? String == "Docs" })
        let lock = (try call("list_actions", ["query": "lock screen", "limit": 5])["actions"] as! [[String: Any]]).first!
        let lockID = lock["id"] as! String
        precondition(lockID == VoiceRegisteredAction.id(for: .command(.lockScreen)) && lock["group"] as? String == "Mac controls")
        let page = try call("list_actions", ["limit": 3, "offset": 2])
        precondition((page["actions"] as! [Any]).count == 3 && (page["total"] as! Int) > 50 && (page["groups"] as! [String]).contains("HUDs"))
        fails("list_actions", ["limit": 0], "integer")
        fails("list_actions", ["limit": true], "integer")
        let keywords = try tools.call("set_action_keywords", arguments: ["action_id": lockID, "keyword_sets": [["lock it", " lock my mac "], ["goodnight"]]], settings: &settings)
        precondition(keywords.changed && settings.actionVocabulary == [ActionVocabulary(actionID: lockID, keywordSets: [["lock it", "lock my mac"], ["goodnight"]])])
        let searched = try call("list_actions", ["query": "goodnight"])["actions"] as! [[String: Any]]
        precondition(searched.count == 1 && searched[0]["id"] as? String == lockID, "Queries match voice keywords")
        let unchanged = try tools.call("set_action_keywords", arguments: ["action_id": lockID, "keyword_sets": [["lock it", "lock my mac"], ["goodnight"]]], settings: &settings)
        precondition(!unchanged.changed)
        fails("set_action_keywords", ["action_id": "action_missing", "keyword_sets": [["x"]]], "No action")
        fails("set_action_keywords", ["action_id": lockID, "keyword_sets": [["lock, now"]]], "commas")
        fails("set_action_keywords", ["action_id": lockID, "keyword_sets": [[String(repeating: "a", count: 121)]]], "1–120")
        fails("set_action_keywords", ["action_id": lockID, "keyword_sets": Array(repeating: ["a"], count: 21)], "20")
        fails("set_action_keywords", ["action_id": lockID, "keyword_sets": "lock"], "array")
        _ = try call("set_action_keywords", ["action_id": lockID, "keyword_sets": []])
        precondition(settings.actionVocabulary == nil, "An empty list clears keywords")

        // HUDs
        var main = try call("list_huds")["huds"] as! [[String: Any]]
        precondition(main.count == 1 && main[0]["id"] as? String == "main" && (main[0]["slots"] as! [String]).count == 8)
        let urlTile = try call("set_hud_tile", ["hud": "main", "direction": "up", "url": "news.example.com", "name": "News"])
        precondition((urlTile["tile"] as? [String: Any])?["kind"] as? String == "website")
        precondition(settings.appExplorer?.favorites.first { $0.direction == .up }?.url == "https://news.example.com")
        _ = try call("set_hud_tile", ["hud": "Main HUD", "direction": "right", "action_id": docsActionID])
        let rightTile = settings.appExplorer!.favorites.first { $0.direction == .right }!
        precondition(rightTile.shortcut?.assignedAction?.url == "https://example.com/docs", "Browser-targeted bookmarks keep their browser on a tile")
        _ = try call("set_hud_tile", ["hud": "main", "direction": "left", "app_bundle_id": "com.apple.Notes"])
        precondition(settings.appExplorer!.favorites.first { $0.direction == .left }?.name == "Notes")
        _ = try call("set_hud_tile", ["hud": "main", "direction": "down", "action_id": lockID])
        precondition(settings.appExplorer!.favorites.first { $0.direction == .down }?.action == .lockScreen)
        fails("set_hud_tile", ["hud": "main", "direction": "sideways", "url": "https://a.example"], "not a slot")
        fails("set_hud_tile", ["hud": "main", "direction": "angle100", "url": "https://a.example"], "not a slot")
        fails("set_hud_tile", ["hud": "main", "direction": "up"], "exactly one")
        fails("set_hud_tile", ["hud": "main", "direction": "up", "url": "https://a.example", "app_bundle_id": "com.apple.Notes"], "exactly one")
        fails("set_hud_tile", ["hud": "main", "direction": "up", "app_bundle_id": "local.rotagivan"], "bundle id")
        fails("set_hud_tile", ["hud": "main", "direction": "up", "url": "ftp://a.example"], "not a valid")
        fails("set_hud_tile", ["hud": "nowhere", "direction": "up", "url": "https://a.example"], "No HUD")

        var explorer = settings.appExplorer!
        let custom = explorer.assignEmptyHUD(at: .right)!
        let window = explorer.assignBuiltIn(.windowManager, at: .left)!
        let media = explorer.assignTemplate(.mediaControls, at: .top)!
        var group = AppExplorerFavorite(direction: .topLeft, name: "Work")
        group.children = [AppExplorerFavorite(direction: .up, bundleID: "com.apple.Notes", name: "Notes")]
        precondition(explorer.setFavorite(group, at: .topLeft))
        settings.appExplorer = explorer
        main = try call("list_huds")["huds"] as! [[String: Any]]
        precondition(main.count == 4)
        let customRow = main.first { $0["id"] as? String == custom.uuidString }!
        precondition(customRow["position"] as? String == "right" && customRow["editable"] as? Bool == true)
        precondition(main.first { $0["id"] as? String == window.uuidString }?["editable"] as? Bool == false)
        let mainTiles = main[0]["tiles"] as! [[String: Any]]
        precondition(mainTiles.first { $0["direction"] as? String == "topLeft" }?["kind"] as? String == "group")
        precondition(mainTiles.map { $0["direction"] as! String }.first == "up", "Tiles follow slot order")

        _ = try call("set_hud_tile", ["hud": "Right HUD", "direction": "up", "url": "https://layer.example"])
        precondition(settings.appExplorer!.holdLayers!.first { $0.id == custom }!.favorites.first?.url == "https://layer.example")
        precondition(settings.appExplorer!.favorites.first { $0.direction == .up }?.url == "https://news.example.com", "Layer writes never touch the main HUD")
        _ = try call("set_hud_tile", ["hud": media.uuidString, "direction": "up", "app_bundle_id": "com.apple.Notes"])
        let mediaLayer = settings.appExplorer!.holdLayers!.first { $0.id == media }!
        precondition(mediaLayer.favorites.contains { $0.bundleID == "com.apple.Notes" } && mediaLayer.favorites.count > 1, "Template tiles stay when one slot changes")
        fails("set_hud_tile", ["hud": window.uuidString, "direction": "up", "url": "https://a.example"], "can't be edited")
        fails("set_hud_tile", ["hud": "main", "direction": "topLeft", "url": "https://a.example"], "replace_group")
        fails("clear_hud_tile", ["hud": "main", "direction": "topLeft"], "remove_group")
        let cleared = try call("clear_hud_tile", ["hud": "main", "direction": "topLeft", "remove_group": true])
        precondition(cleared["cleared"] as? Bool == true && settings.appExplorer!.favorites.first { $0.direction == .topLeft } == nil)
        let empty = try tools.call("clear_hud_tile", arguments: ["hud": "main", "direction": "topLeft"], settings: &settings)
        precondition(!empty.changed)
        precondition(settings.appExplorer!.hasValidFavorites)

        // Macros
        settings.hotkeyDictionary = [NamedHotkey(name: "Comment", shortcut: RecordedShortcut(keyCode: 44, modifiers: 1 << 20, keyLabel: "/"))]
        let macros = try call("list_macros")["macros"] as! [[String: Any]]
        precondition(macros.count == 1 && macros[0]["name"] as? String == "Comment" && macros[0]["action_id"] as? String == VoiceRegisteredAction.id(for: .macro(settings.hotkeyDictionary![0])))
        fails("list_macros", ["x": 1], "Unknown argument")
        fails("drop_settings", [:], "Unknown tool")
        let decoded = try JSONDecoder().decode(StoredSettings.self, from: JSONEncoder().encode(settings))
        precondition(decoded.appExplorer == settings.appExplorer && decoded.websiteBookmarks == settings.websiteBookmarks)
    }

    @MainActor static func bridgeTests() throws {
        let suite = "mcp-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = URL(fileURLWithPath: "/private/tmp/rmcp-" + String(UUID().uuidString.prefix(8)), isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let socket = directory.appendingPathComponent("bridge.sock")
        let store = SettingsStore(defaults: defaults)
        let bridge = MCPBridgeServer(defaults: defaults, socketURL: socket)
        bridge.attach(store: store)
        precondition(!bridge.isEnabled && !bridge.isListening && !FileManager.default.fileExists(atPath: socket.path), "Off by default: no socket")
        let disabled = bridge.perform("list_bookmarks", arguments: [:])
        precondition(!disabled.ok && disabled.text == MCPBridgeEndpoint.unavailableMessage)
        let offline = MCPBridgeClient.call(tool: "list_bookmarks", arguments: [:], socketPath: socket.path)
        precondition(!offline.ok && offline.text == MCPBridgeEndpoint.unavailableMessage)

        bridge.setEnabled(true)
        precondition(bridge.isListening && defaults.bool(forKey: MCPBridgeEndpoint.enabledKey), bridge.error ?? "not listening")
        let socketMode = (try FileManager.default.attributesOfItem(atPath: socket.path)[.posixPermissions] as! NSNumber).intValue
        let directoryMode = (try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as! NSNumber).intValue
        precondition(socketMode & 0o777 == 0o600 && directoryMode & 0o777 == 0o700, "Socket 0600 inside a 0700 directory")

        func remote(_ tool: String, _ arguments: [String: Any]) -> (ok: Bool, text: String) {
            nonisolated(unsafe) var result: (ok: Bool, text: String)?
            nonisolated(unsafe) let payload = arguments
            let path = socket.path
            Thread.detachNewThread { result = MCPBridgeClient.call(tool: tool, arguments: payload, socketPath: path) }
            let deadline = Date().addingTimeInterval(10)
            while result == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            return result ?? (false, "timeout")
        }
        let add = remote("add_bookmarks", ["bookmarks": [["url": "https://bridge.example", "name": "Bridge"]]])
        precondition(add.ok && json(add.text)["total_bookmarks"] as? Int == 1, add.text)
        precondition(store.settings.resolvedWebsiteBookmarks.first?.url == "https://bridge.example", "Writes reach SettingsStore")
        let saved = try JSONDecoder().decode(StoredSettings.self, from: defaults.data(forKey: "settings.v1")!)
        precondition(saved.resolvedWebsiteBookmarks.count == 1, "Writes persist like Settings edits")
        let invalid = remote("set_hud_tile", ["hud": "main", "direction": "nowhere", "url": "https://bridge.example"])
        precondition(!invalid.ok && invalid.text.contains("not a slot"))
        // Concurrent clients are served independently.
        let first = remote("list_bookmarks", [:]), second = remote("get_settings_summary", [:])
        precondition(first.ok && second.ok && first.text.contains("bridge.example"))

        bridge.setEnabled(false)
        precondition(!bridge.isListening && !FileManager.default.fileExists(atPath: socket.path), "Turning off removes the socket")
        let after = MCPBridgeClient.call(tool: "list_bookmarks", arguments: [:], socketPath: socket.path)
        precondition(!after.ok && after.text == MCPBridgeEndpoint.unavailableMessage)

        // A stale socket file from a crash is replaced; a live one is never stolen.
        bridge.setEnabled(true)
        let competitor = MCPBridgeServer(defaults: defaults, socketURL: socket)
        competitor.attach(store: store)
        precondition(!competitor.isListening && competitor.error?.contains("Another Rotagivan") == true)
        bridge.stop()
        FileManager.default.createFile(atPath: socket.path, contents: Data())
        competitor.start()
        precondition(competitor.isListening, competitor.error ?? "stale socket was not replaced")
        competitor.stop()
    }
}
