# Performance audit

Every interaction was measured on the main thread with `Rotagivan/benchmark.sh`
(a synthetic heavy configuration: 12 HUD layers × 8 tiles, 60 bookmarks,
40 macros, 3 profiles, 600 indexed apps) and with a HUD open/close harness.
Numbers are medians on an M-series Mac, optimized build. Run the script before
and after any change that touches these paths.

| Interaction | Before | After | What changed |
| --- | ---: | ---: | --- |
| HUD open, steady state (`show()`) | 19 ms | 3 ms | One panel and SwiftUI tree reused across opens; the entrance animation replays. |
| HUD first open after launch | ~330 ms | ~20 ms | Hidden warm-up draw 1.5 s after launch decodes tile icons, installs the first key monitor, prefetches favicons. |
| HUD frame while the selection changes | 8.8 ms | 3.6 ms | Tile labels keep one font weight; selection no longer re-rasterizes text through the autohinter. The lens blur is GPU-rasterized. |
| HUD frame, nothing moving | 4.3 ms | 1.8 ms | Same. |
| Swipe report → model update | 0.2–1 ms | — | Already cheap. |
| Bookmark tiles after relaunch | network fetch | instant | Favicons cached on disk for a week; known icons skip the 300 ms fetch delay. |
| Chrome tabs HUD open | blank until AppleScript | previous snapshot at once | Fresh snapshot replaces it; the script asks Chrome per window, not per tab. |
| Chrome recency sampler (every 2 s while Chrome is frontmost) | AppleScript each tick | AX title read; AppleScript only when the title changed | |
| Settings slider tick (one `settings` change) | 2.4 ms | 0.6 ms | Profile library written once per run-loop turn; explicit renames still write at once. |
| Launcher search per keystroke, Swift fallback engine (966 rows) | 2.2–2.8 ms | 1.5–2.0 ms | Folded names and bundle ids cached per app instead of refolded on every keystroke; the rest is scoring plus a localized sort of the matches. The bundled Rust engine keeps its own index. |
| Profile switch | 2.4 ms + full HID stop/start (~10 ms without a device, plus the Navigator leaving and re-entering precision mode) | 2.4 ms + gesture reset only | When both profiles use the same device settings the trackpad stays open; only gesture state resets and Apple input re-reads its settings. Different device settings still reopen the devices. |
| Settings window: Actions / General first render | 33 / 37 ms | 24 / 21 ms | Buttons, switch knobs and segmented knobs drew half-point blurred shadows, one offscreen pass each; they now draw an equivalent hairline. Remaining cost is card rasterization. |
| Settings window: HUD page, no layers | 108 ms | 81 ms | Preview faces drop the material, drop shadow and per-label shadows; the navigator and side panes use a flat tint instead of a material over the opaque window. |
| Settings window: HUD page, 12 layers | 360 ms | 173 ms | Each satellite face is one GPU raster (`drawingGroup`). Remaining cost is one full HUD layout per layer. |
| Settings window: Calibration tab (opened on demand) | 188 ms | 59 ms | The scope bar and calibration control show at once; the recognition cards lay out one frame later. |
| Voice/action registry build (`VoiceActionRegistry.make`, 600 apps) — every HUD open, MCP call and usage-tracker refresh | 60 ms | 0.6 ms | Base and finished lists cached per settings/applications/scope; record ids computed once instead of hashing JSON on every access. |
| MCP tool call round trip (`get_settings_summary`) | 62 ms | 0.7 ms | Same cache; the socket itself costs under 0.1 ms. `list_actions` 82 → 4 ms. |
| Launcher catalog per keystroke | rebuilt 966 rows + compared | reused | Catalog array rebuilt only when a snapshot arrives. |
| Sync after an edit | 5.4 ms on main | ~0 on main | Field encoding runs on a background task; only the snapshot copy stays on the main actor. |
| Timer alert glow (breathing, every screen) | 5.4% of a core | 3.5% | Blurred ring rasterized once on the GPU; only its opacity animates. |
| Idle CPU (app in background) | 0.0% | 0.0% | Timers: Slack/Chrome title sampling 2 s (cheap AX reads), usage tracker 5 s, update check hourly, sync poll hourly. |
| Timer, media controls, built-in HUD switches | model updates only | — | Same render path as the HUD above. |

Also found and fixed: 25,174 leftover `UserDefaults` suite files from test runs in
`~/Library/Preferences` (test.sh now sweeps them), which slowed every
`defaults` operation on the machine.

## Simplicity changes made alongside

- One way to assign anything to a tile: the current-assignment card opens the
  action picker, which includes Built-in HUDs. The separate groups menu and the
  legacy slot menu's built-in items are gone.
- Only the Starburst Air HUD exists; theme pickers are gone.
- Swipe directions and tap calibration each have one home under HUD › Taps & swipes.

## Not changed, and why

- Voice mode latency is dominated by the speech provider; nothing on the main
  thread blocks it.
- The Calibration tab's 190 ms is paid once per visit; its cards could be
  made lazy if it is opened often.
- HUD workspace cost still scales ~9 ms per layer for the full-detail satellite
  faces. Rendering faces to cached images would remove it at the cost of
  stale previews while editing.
