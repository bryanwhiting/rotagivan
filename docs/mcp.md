# Local agents (MCP)

Rota can act as a local [Model Context Protocol](https://modelcontextprotocol.io) server so an AI agent running on this Mac (Claude Code, Claude Desktop, or any MCP client) can read and edit a bounded set of settings: website bookmarks, HUD tiles, voice keywords, and read-only lists of actions and macros.

It is **off by default** and **device-only**. Nothing about it syncs.

## Turning it on

Settings → General → **Agents (MCP)** → *Allow local agents (MCP)*.

While it is on, the app listens on a Unix socket at
`~/Library/Application Support/Rota/MCP/bridge.sock` (directory `0700`, socket `0600`). Every connection is checked with `getpeereid`, so only processes running as the same macOS user are answered. Turning the toggle off removes the socket.

## Connecting a client

The MCP server itself is a small stdio helper inside the app bundle. It holds no settings; every tool call is forwarded to the running app over the socket, and the app validates and applies it on the main thread through the normal settings store, so changes persist, encrypt and sync exactly like edits made in Settings.

Claude Code:

```sh
claude mcp add rota -- /Applications/Rota.app/Contents/MacOS/rota-mcp
```

Claude Desktop and other JSON-configured clients:

```json
{
  "mcpServers": {
    "rota": {
      "command": "/Applications/Rota.app/Contents/MacOS/rota-mcp"
    }
  }
}
```

Both snippets are available with a Copy button in the Agents (MCP) card. `tools/list` works even when the app is closed; `tools/call` needs the app running with the toggle on and otherwise returns a clear message.

## Tools

| Tool | Writes | What it does |
| --- | --- | --- |
| `get_settings_summary` | no | Counts of bookmarks, HUDs, macros, actions and keyword sets. |
| `list_bookmarks` | no | Website bookmarks with URL, browser and `action_id`. |
| `add_bookmarks` | yes | Add up to 200 http(s) bookmarks per call (`url`, optional `name`, `browser`: chrome/safari/default). Duplicates and invalid URLs are reported, not added. |
| `remove_bookmark` | yes | Remove the bookmark with a given URL. |
| `list_actions` | no | Actions from the Actions list with ids, groups, details and keyword sets; filter by `query`, `group`, page with `limit`/`offset`. |
| `set_action_keywords` | yes | Replace the voice keyword sets of one action (`keyword_sets`: up to 20 sets of up to 12 phrases). An empty list clears them. |
| `list_huds` | no | Main HUD and each layer: id, name, map position, slot directions and tiles. |
| `set_hud_tile` | yes | Put one destination in a slot: exactly one of `action_id`, `url` or `app_bundle_id`. Replacing a group needs `replace_group: true`. |
| `clear_hud_tile` | yes | Empty one slot. Removing a group needs `remove_group: true`. |
| `list_macros` | no | Macro ids, names, step summaries and activation hotkeys. |

Generated built-in HUDs (Chrome tabs, recent apps, Slack channels, window manager and so on) are listed but not editable.

## What agents can never do

- Run actions, macros, shortcuts or send keystrokes.
- Read or change API keys, sync credentials, the vault, or sync state.
- Change anything other than the settings listed above.
- Reach the app from another user account or over the network.

Requests and responses are capped at 1 MB and 8 MB, sockets time out after 10–15 seconds, and the helper exits cleanly when its client closes stdin.

## Troubleshooting

- *"Rota is not accepting agent connections"*: open the app and turn on the toggle in General → Agents (MCP).
- *"Another Rota is already serving local agents"*: a second copy of the app is running; quit it.
- The helper path is fixed to `/Applications/Rota.app`. If the app lives elsewhere, point the client at that bundle's `Contents/MacOS/rota-mcp`.

Tests: `Rota/Tests/MCPTests.swift` (tool validation, socket framing, peer checks and the JSON-RPC state machine), run by `Rota/test.sh`.
