import Foundation

/// In-app end of the local agent bridge. Off by default and device-only: the
/// socket exists only while the user allows local agents. Requests come from
/// the same user (getpeereid) and run on the main actor against SettingsStore.
@MainActor final class MCPBridgeServer: ObservableObject {
    static let shared = MCPBridgeServer()

    @Published private(set) var isListening = false
    @Published private(set) var error: String?
    @Published private(set) var lastRequest: Date?

    private let defaults: UserDefaults
    private let socketURL: URL
    private var store: SettingsStore?
    private var applications: @MainActor () -> [ExplorerApplication] = { [] }
    private var descriptor: Int32 = -1
    private var source: DispatchSourceRead?
    private nonisolated let queue = DispatchQueue(label: "local.rotagivan.mcp", attributes: .concurrent)

    init(defaults: UserDefaults = .standard, socketURL: URL = MCPBridgeEndpoint.socketURL) {
        self.defaults = defaults
        self.socketURL = socketURL
    }

    var isEnabled: Bool { defaults.bool(forKey: MCPBridgeEndpoint.enabledKey) }

    func attach(store: SettingsStore, applications: @escaping @MainActor () -> [ExplorerApplication] = { [] }) {
        self.store = store
        self.applications = applications
        if isEnabled { start() }
    }

    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: MCPBridgeEndpoint.enabledKey)
        enabled ? start() : stop()
    }

    func start() {
        guard descriptor < 0, isEnabled else { return }
        // SO_NOSIGPIPE cannot be set once a peer has already hung up, so a
        // client that disconnects early must never terminate the app.
        signal(SIGPIPE, SIG_IGN)
        do {
            descriptor = try listen()
            let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
            let listener = descriptor
            source.setEventHandler { [weak self] in
                while true {
                    let client = accept(listener, nil, nil)
                    guard client >= 0 else { return }
                    self?.serve(client)
                }
            }
            source.setCancelHandler { close(listener) }
            source.resume()
            self.source = source
            isListening = true
            error = nil
        } catch let failure as MCPToolError {
            error = failure.message
            isListening = false
        } catch {}
    }

    func stop() {
        source?.cancel()
        source = nil
        if descriptor >= 0 { unlink(socketURL.path) }
        descriptor = -1
        isListening = false
    }

    private func listen() throws -> Int32 {
        let directory = socketURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } catch { throw MCPToolError("Could not prepare \(directory.path).") }
        guard var address = MCPSocket.address(socketURL.path) else { throw MCPToolError("The socket path is too long.") }
        // Never steal a socket another running copy is serving; remove only stale files.
        if FileManager.default.fileExists(atPath: socketURL.path) {
            if MCPBridgeClient.probe(socketPath: socketURL.path) { throw MCPToolError("Another Rotagivan is already serving local agents.") }
            unlink(socketURL.path)
        }
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw MCPToolError("Could not create the agent socket.") }
        let previous = umask(0o177)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        umask(previous)
        guard bound == 0, chmod(socketURL.path, 0o600) == 0, Darwin.listen(listener, 8) == 0 else {
            close(listener)
            throw MCPToolError("Could not listen for local agents (\(String(cString: strerror(errno)))).")
        }
        _ = fcntl(listener, F_SETFL, fcntl(listener, F_GETFL) | O_NONBLOCK)
        return listener
    }

    private nonisolated func serve(_ client: Int32) {
        queue.async {
            defer { close(client) }
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
            MCPSocket.setTimeout(client, seconds: 10)
            guard MCPSocket.peerIsCurrentUser(client) else { return }
            let reply: (ok: Bool, text: String)
            if let line = MCPSocket.readLine(client, limit: MCPBridgeEndpoint.maximumLineBytes),
               let request = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
               let tool = request["tool"] as? String {
                let arguments = request["arguments"] as? [String: Any] ?? [:]
                let data = try? JSONSerialization.data(withJSONObject: arguments)
                reply = DispatchQueue.main.sync {
                    MainActor.assumeIsolated {
                        let decoded = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                        return self.perform(tool, arguments: decoded)
                    }
                }
            } else {
                reply = (false, "Malformed or oversized request (limit 1 MB).")
            }
            if let data = try? JSONSerialization.data(withJSONObject: ["ok": reply.ok, "text": reply.text]) { _ = MCPSocket.writeAll(client, data + Data([10])) }
        }
    }

    /// Validates and applies one tool call. Writes go through `store.settings`,
    /// so they persist, encrypt and sync like any Settings edit.
    func perform(_ tool: String, arguments: [String: Any]) -> (ok: Bool, text: String) {
        guard isEnabled else { return (false, MCPBridgeEndpoint.unavailableMessage) }
        guard let store else { return (false, "Rotagivan is still starting. Try again in a moment.") }
        lastRequest = Date()
        let tools = MCPSettingsTools(applications: applications())
        var settings = store.settings
        do {
            let outcome = try tools.call(tool, arguments: arguments, settings: &settings)
            if outcome.changed { store.settings = settings }
            return (true, MCPSettingsTools.render(outcome.result))
        } catch let error as MCPToolError {
            return (false, error.message)
        } catch {
            return (false, "The tool failed.")
        }
    }
}

extension MCPBridgeClient {
    /// True when something is accepting connections on the socket.
    static func probe(socketPath: String) -> Bool {
        guard var address = MCPSocket.address(socketPath) else { return false }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        } == 0
    }
}
