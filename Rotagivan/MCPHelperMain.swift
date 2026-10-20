import Foundation

/// `Contents/MacOS/rotagivan-mcp`: the stdio MCP server agents launch. It holds
/// no settings and never runs actions; tool calls go to the running app.
/// stdout carries protocol messages only; diagnostics go to stderr.
@main enum RotagivanMCPHelper {
    static func main() {
        signal(SIGPIPE, SIG_IGN)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let server = MCPStdioServer(version: version) { tool, arguments in
            MCPBridgeClient.call(tool: tool, arguments: arguments)
        }
        var pending = Data()
        var discarding = false
        var buffer = [UInt8](repeating: 0, count: 65_536)
        func emit(_ line: String) {
            guard MCPSocket.writeAll(STDOUT_FILENO, Data((line + "\n").utf8)) else { exit(0) }
        }
        while true {
            let count = read(STDIN_FILENO, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return }
            var chunk = buffer[0..<count][...]
            while let newline = chunk.firstIndex(of: 10) {
                if discarding {
                    discarding = false
                    emit(MCPStdioServer.encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32600, "message": "Request exceeds 1 MB."]]))
                } else {
                    pending.append(contentsOf: chunk[chunk.startIndex..<newline])
                    if !pending.allSatisfy({ $0 == 32 || $0 == 13 || $0 == 9 }), let reply = server.handle(line: pending) { emit(reply) }
                }
                pending.removeAll(keepingCapacity: true)
                chunk = chunk[(newline + 1)...]
            }
            if !discarding { pending.append(contentsOf: chunk) }
            if pending.count > MCPBridgeEndpoint.maximumLineBytes {
                FileHandle.standardError.write(Data("rotagivan-mcp: dropping oversized request\n".utf8))
                pending.removeAll(); discarding = true
            }
        }
    }
}
