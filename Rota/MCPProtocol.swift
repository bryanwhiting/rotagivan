import Foundation

/// Shared by the stdio helper and the app. The helper speaks MCP (JSON-RPC 2.0,
/// newline-delimited) to an agent and forwards only `tools/call` to the running
/// app over a same-user Unix socket. Nothing here touches settings directly.
enum MCPBridgeEndpoint {
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Rota/MCP", isDirectory: true)
    static var socketURL: URL { directory.appendingPathComponent("bridge.sock") }
    static let enabledKey = "mcp.localAgentsEnabled"
    static let maximumLineBytes = 1_048_576
    static let maximumResponseBytes = 8 * 1_048_576
    static let helperPath = "/Applications/Rota.app/Contents/MacOS/rota-mcp"
    static var claudeCodeCommand: String { "claude mcp add rota -- " + helperPath }
    static var jsonConfiguration: String {
        "{\n  \"mcpServers\": {\n    \"rota\": {\n      \"command\": \"\(helperPath)\"\n    }\n  }\n}"
    }
    static let unavailableMessage = "Rota is not accepting agent connections. Open Rota, go to General › Agents (MCP), and turn on “Allow local agents (MCP)”."
}

/// Raw POSIX socket helpers so both processes share one framing and peer check.
enum MCPSocket {
    static func address(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }

    static func peerIsCurrentUser(_ descriptor: Int32) -> Bool {
        var uid: uid_t = 0, gid: gid_t = 0
        return getpeereid(descriptor, &uid, &gid) == 0 && uid == getuid()
    }

    static func setTimeout(_ descriptor: Int32, seconds: Int) {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Reads one newline-terminated line. Nil on EOF before a newline, timeout or overflow.
    static func readLine(_ descriptor: Int32, limit: Int) -> Data? {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            guard count > 0 else { return nil }
            if let newline = buffer[0..<count].firstIndex(of: 10) {
                result.append(contentsOf: buffer[0..<newline])
                return result.count <= limit ? result : nil
            }
            result.append(contentsOf: buffer[0..<count])
            guard result.count <= limit else { return nil }
        }
    }

    static func writeAll(_ descriptor: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(descriptor, raw.baseAddress! + offset, raw.count - offset)
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
    }
}

/// Wire format between helper and app: one request line, one response line.
/// Request `{"tool": name, "arguments": {...}}`; response `{"ok": Bool, "text": String}`.
enum MCPBridgeClient {
    static func call(tool: String, arguments: [String: Any], socketPath: String = MCPBridgeEndpoint.socketURL.path) -> (ok: Bool, text: String) {
        guard let request = try? JSONSerialization.data(withJSONObject: ["tool": tool, "arguments": arguments]),
              request.count <= MCPBridgeEndpoint.maximumLineBytes else { return (false, "The request is too large.") }
        guard var address = MCPSocket.address(socketPath) else { return (false, "The Rota socket path is too long.") }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return (false, "Could not create a local socket.") }
        defer { close(descriptor) }
        MCPSocket.setTimeout(descriptor, seconds: 15)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { return (false, MCPBridgeEndpoint.unavailableMessage) }
        guard MCPSocket.peerIsCurrentUser(descriptor) else { return (false, "The Rota socket belongs to another user.") }
        guard MCPSocket.writeAll(descriptor, request + Data([10])),
              let line = MCPSocket.readLine(descriptor, limit: MCPBridgeEndpoint.maximumResponseBytes),
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let ok = object["ok"] as? Bool, let text = object["text"] as? String else {
            return (false, "Rota did not answer. Make sure the app is running and try again.")
        }
        return (ok, text)
    }
}

/// Static tool catalogue so agents can list tools even while the app is closed.
enum MCPToolCatalog {
    private static func object(_ properties: [String: Any], required: [String] = []) -> [String: Any] {
        var schema: [String: Any] = ["type": "object", "properties": properties, "additionalProperties": false]
        if !required.isEmpty { schema["required"] = required }
        return schema
    }
    private static let string: [String: Any] = ["type": "string"]
    private static let hud: [String: Any] = ["type": "string", "description": "\"main\", a HUD id, or a HUD name from list_huds."]
    private static let direction: [String: Any] = ["type": "string", "description": "A slot from list_huds, e.g. up, topRight, right, bottomRight, down, bottomLeft, left, topLeft."]
    private static let browser: [String: Any] = ["type": "string", "enum": ["chrome", "safari", "default"]]

    static let tools: [[String: Any]] = [
        ["name": "get_settings_summary", "title": "Settings summary",
         "description": "Counts of bookmarks, HUDs, macros, actions and voice keywords. Never includes credentials.",
         "inputSchema": object([:]), "annotations": ["readOnlyHint": true]],
        ["name": "list_bookmarks", "title": "List website bookmarks",
         "description": "Website bookmarks with their URL, browser and action_id (usable with set_hud_tile).",
         "inputSchema": object([:]), "annotations": ["readOnlyHint": true]],
        ["name": "add_bookmarks", "title": "Add website bookmarks",
         "description": "Add up to 200 http(s) website bookmarks. Missing schemes default to https. Duplicates and invalid URLs are reported, not added.",
         "inputSchema": object(["bookmarks": ["type": "array", "maxItems": 200, "items": object(
            ["url": string, "name": string, "browser": browser], required: ["url"])]], required: ["bookmarks"]),
         "annotations": ["readOnlyHint": false, "destructiveHint": false]],
        ["name": "remove_bookmark", "title": "Remove a website bookmark",
         "description": "Remove the bookmark with this URL (as shown by list_bookmarks).",
         "inputSchema": object(["url": string], required: ["url"]),
         "annotations": ["readOnlyHint": false, "destructiveHint": true]],
        ["name": "list_actions", "title": "List actions",
         "description": "Actions from the Actions list: id, name, group, detail and voice keyword sets. Filter with a case-insensitive query or exact group.",
         "inputSchema": object(["query": string, "group": string,
            "limit": ["type": "integer", "minimum": 1, "maximum": 500], "offset": ["type": "integer", "minimum": 0]]),
         "annotations": ["readOnlyHint": true]],
        ["name": "set_action_keywords", "title": "Set voice keywords",
         "description": "Replace the voice keyword sets for an action id. Each set is a list of alternative phrases (max 20 sets, 12 phrases each, 120 characters per phrase). An empty list clears them.",
         "inputSchema": object(["action_id": string, "keyword_sets": ["type": "array", "maxItems": 20,
            "items": ["type": "array", "maxItems": 12, "items": string]]], required: ["action_id", "keyword_sets"]),
         "annotations": ["readOnlyHint": false, "destructiveHint": false]],
        ["name": "list_huds", "title": "List HUDs",
         "description": "The main HUD and each HUD layer: id, name, map position, slot directions and tiles.",
         "inputSchema": object([:]), "annotations": ["readOnlyHint": true]],
        ["name": "set_hud_tile", "title": "Set a HUD tile",
         "description": "Place one destination in a HUD slot: exactly one of action_id (from list_actions or list_bookmarks), url, or app_bundle_id. Replaces an existing non-group tile; group tiles need replace_group=true.",
         "inputSchema": object(["hud": hud, "direction": direction, "action_id": string, "url": string,
            "app_bundle_id": string, "name": string, "browser": browser, "replace_group": ["type": "boolean"]],
            required: ["hud", "direction"]),
         "annotations": ["readOnlyHint": false, "destructiveHint": true]],
        ["name": "clear_hud_tile", "title": "Clear a HUD tile",
         "description": "Empty one HUD slot. Group tiles need remove_group=true because their nested tiles are removed too.",
         "inputSchema": object(["hud": hud, "direction": direction, "remove_group": ["type": "boolean"]], required: ["hud", "direction"]),
         "annotations": ["readOnlyHint": false, "destructiveHint": true]],
        ["name": "list_macros", "title": "List macros",
         "description": "Saved macros: id, name, step summary and activation hotkey.",
         "inputSchema": object([:]), "annotations": ["readOnlyHint": true]]
    ]
    static let names = Set(tools.compactMap { $0["name"] as? String })
}

/// JSON-RPC state machine for the stdio helper. `forward` performs `tools/call`.
struct MCPStdioServer {
    static let protocolVersion = "2025-06-18"
    static let supportedVersions: Set<String> = ["2025-06-18", "2025-03-26", "2024-11-05"]
    var version = "1.0"
    var forward: (String, [String: Any]) -> (ok: Bool, text: String)

    private func response(_ id: Any?, result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result]
    }
    private func failure(_ id: Any?, _ code: Int, _ message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]]
    }
    static func encode(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32603,\"message\":\"Internal error\"}}"
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Returns the response line, or nil for notifications and responses.
    func handle(line: Data) -> String? {
        guard line.count <= MCPBridgeEndpoint.maximumLineBytes else { return Self.encode(failure(nil, -32600, "Request exceeds 1 MB.")) }
        guard let parsed = try? JSONSerialization.jsonObject(with: line) else { return Self.encode(failure(nil, -32700, "Parse error")) }
        guard let message = parsed as? [String: Any] else { return Self.encode(failure(nil, -32600, "Batch requests are not supported.")) }
        let id = message["id"]
        guard let method = message["method"] as? String else {
            // A client response (we never send requests) or malformed message.
            return id == nil || message["result"] != nil || message["error"] != nil ? nil : Self.encode(failure(id, -32600, "Invalid request"))
        }
        guard let id, id is String || id is NSNumber else {
            return message.keys.contains("id") ? Self.encode(failure(nil, -32600, "Invalid request id")) : nil
        }
        let params = message["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String
            return Self.encode(response(id, result: [
                "protocolVersion": requested.flatMap { Self.supportedVersions.contains($0) ? $0 : nil } ?? Self.protocolVersion,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "rota", "title": "Rota", "version": version],
                "instructions": "Reads and edits Rota settings on this Mac: website bookmarks, HUD tiles, voice keywords. Use list_* tools to find ids before writing. Changes save and sync like edits made in Settings."
            ]))
        case "ping":
            return Self.encode(response(id, result: [:]))
        case "tools/list":
            return Self.encode(response(id, result: ["tools": MCPToolCatalog.tools]))
        case "tools/call":
            guard let name = params["name"] as? String, MCPToolCatalog.names.contains(name) else {
                return Self.encode(failure(id, -32602, "Unknown tool"))
            }
            if let arguments = params["arguments"], !(arguments is [String: Any]) {
                return Self.encode(failure(id, -32602, "Tool arguments must be an object."))
            }
            let outcome = forward(name, params["arguments"] as? [String: Any] ?? [:])
            return Self.encode(response(id, result: ["content": [["type": "text", "text": outcome.text]], "isError": !outcome.ok]))
        default:
            return Self.encode(failure(id, -32601, "Method not found: " + method))
        }
    }
}
