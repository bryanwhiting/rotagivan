# Rota

Rota is a Tauri 2 + Rust reimplementation of the trackpad control app, with a
React/TypeScript settings surface and a Three.js spatial HUD.

## What is implemented

- Multiple named profiles with independent HUD, pointer, scroll, and calibration settings.
- Navigator and Apple-trackpad device routing controls.
- Editable 2–16 slot HUD layers, four-way placement, themes, per-tile actions,
  hold-for-depth children, and live immersive preview.
- Three.js quaternion rotation, direct manipulation, velocity decay, layer
  navigation, GPU-rendered glass sectors, and reduced-motion handling.
- Pointer and scroll response curves, inversion, coasting, and drag settings.
- Tap/swipe calibration settings.
- Editable multi-step Custom Commands and app-specific overrides.
- A shared six-family action hierarchy for window management, media control,
  system actions, macOS settings, apps and bookmarks, and Custom Commands.
- A native macOS menu bar with standard app, edit, and window behavior plus
  direct access to the full action hierarchy, HUD, and settings destinations.
- Rust-owned atomic settings persistence and simplified native action adapters.
- A local MCP Streamable HTTP server through which agents can read or edit every setting.

The low-level hardware adapter is intentionally a prototype boundary. The UI,
settings model, persistence, MCP tools, and HUD interaction are functional; raw
HID capture and synthetic event posting can be filled in behind
`perform_native_action` without changing the frontend or MCP contract.

## Development

```sh
npm install
npm run tauri dev
```

Build the production macOS app:

```sh
npm run tauri build -- --bundles app
```

Or build, copy to `/Applications/Rota.app`, and launch:

```sh
./launch.sh
```

## Rota MCP server

While Rota is running, connect an MCP client to:

```text
http://127.0.0.1:4782/mcp
```

The endpoint is bound to localhost and exposes:

- `rota_get_settings`
- `rota_get_setting`
- `rota_set_setting`
- `rota_delete_setting`
- `rota_patch_settings`
- `rota_replace_settings`
- `rota_settings_guide`

Agents should call `rota_get_settings` first, preserve existing IDs and value
types, then use `rota_set_setting` for one field or `rota_patch_settings` for a
multi-field RFC 6902 update. Rota persists the edit atomically and the open UI
adopts external MCP changes automatically.

Example client configuration:

```json
{
  "mcpServers": {
    "rota": {
      "url": "http://127.0.0.1:4782/mcp"
    }
  }
}
```

## Verification

```sh
npm run build
cd src-tauri
cargo test
cargo check
```
