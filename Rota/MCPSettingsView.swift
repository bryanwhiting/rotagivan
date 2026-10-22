import AppKit
import SwiftUI

/// General › Agents (MCP). Device-only; never synced.
struct MCPSettingsCard: View {
    @ObservedObject var bridge: MCPBridgeServer = .shared
    @State private var enabled = MCPBridgeServer.shared.isEnabled
    @State private var copied: String?

    var body: some View {
        RotaCard("Agents (MCP)", systemImage: "point.3.connected.trianglepath.dotted",
                 subtitle: "Let AI agents on this Mac read and edit bookmarks, HUD tiles and voice keywords.") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Allow local agents (MCP)", isOn: Binding(get: { enabled }, set: { value in
                    enabled = value
                    bridge.setEnabled(value)
                }))
                .toggleStyle(.rotaSwitch)
                .accessibilityIdentifier("mcp-enabled")
                Text("Off by default. When on, agents you run as this macOS user can change these settings. Agents cannot run actions, send keystrokes or read credentials. Changes save and sync like edits made here.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let error = bridge.error, enabled {
                    Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                } else if enabled {
                    Label(bridge.isListening ? "Listening for local agents" : "Starting…",
                          systemImage: bridge.isListening ? "checkmark.circle" : "hourglass")
                        .font(.caption).foregroundStyle(.secondary)
                }
                snippet("Claude Code", MCPBridgeEndpoint.claudeCodeCommand, id: "mcp-copy-command")
                snippet("Claude Desktop and other MCP clients (JSON)", MCPBridgeEndpoint.jsonConfiguration, id: "mcp-copy-json")
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func snippet(_ title: String, _ value: String, id: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button(copied == id ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                    copied = id
                }
                .buttonStyle(.rotaSecondary)
                .accessibilityIdentifier(id)
            }
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: RotaTokens.Radius.m, style: .continuous).fill(RotaTokens.subtleFill))
        }
    }
}
