# Performance audit

Every interaction was measured on the main thread with `Rota/benchmark.sh`
(a synthetic heavy configuration: 12 HUD layers × 8 tiles, 60 bookmarks,
40 macros, 3 profiles, 600 indexed apps) and with a HUD open/close harness.
Numbers are medians on an M-series Mac, optimized build. Run the script before
and after any change that touches these paths. `benchmark.sh --only-chrome`
times tab activation against a running Chrome (it brings Chrome to the front)
and `--only-macro` times a three-chord macro without posting keys.

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
| Chrome tab tile → tab in front (`ChromeBookmarkTabs.activate`, live Chrome, 7 windows / 43 tabs) | 33 ms | 3 ms | AppleScript's `activate` verb alone cost 25 ms (50 ms when Chrome was behind another app); the script now only orders the tab and window, and Launch Services activation (`NSRunningApplication.activate`, <3 ms, frontmost ~5 ms later) brings Chrome forward when it is not already. The window/tab count round trips are gone (out-of-range raises inside the `try`). Scripts compile once per process and take parameters as Apple event arguments (compile was only 0.5 ms; the big win is the verb). `osascript` was never used: a spawn measured 6 s. |
| Bookmark / website-macro open of an already-open tab (`ChromeBookmarkTabs.open`) | 50–60 ms | 8 ms | Two list reads per window (`URL of every tab`, `id of every tab`) with the four-rank choice made inside the script, instead of up to four passes of two round trips per tab; same ranking (last selection, exact match, most recent on site, any on site, in window and tab order), same new-tab fallback. |
| Macro, three chords (default delay, playback lane end to end) | 400 ms | 97 ms | Default inter-step delay 100 → 35 ms (still per-macro configurable, 0–2000). Within a chord, modifier changes and the key down post back-to-back (the HID tap delivers them in order) and only the key up waits an 8 ms hold: 64 → 8 ms per chord. The per-step frontmost check costs <0.01 ms and stays. |
| Macro start from a HUD tile / hotkey | dismiss + 2 run-loop hops | dismiss + 1 hop | `postSequence` enqueues on the main actor directly when already on the main thread; the HUD has no dismiss animation (`orderOut`), the remaining hop lets the panel leave before keys go. |
| Scoped macro: wait for the app/browser to be frontmost | 4 stable samples 25 ms apart (≥100 ms) | 4 samples 10 ms apart (≥40 ms), same 2 s bound | Same stability rule and cancellation on focus elsewhere. |
| Settings slider tick (one `settings` change) | 2.4 ms | 0.6 ms | Profile library written once per run-loop turn; explicit renames still write at once. |
| Launcher search per keystroke, Swift fallback engine (966 rows) | 2.2–2.8 ms | 0.9–1.3 ms | Folded names, bundle ids and their character arrays cached per app; only the shown top matches are ordered (bounded insertion); no per-token array allocations. The bundled Rust engine keeps its own index. |
| Profile switch | 2.4 ms + full HID stop/start (~10 ms without a device, plus the Navigator leaving and re-entering precision mode) | 2.4 ms + gesture reset only | The trackpad stays open unless the new profile enables or disables the Navigator itself; gesture state resets and Apple input re-reads its settings in place. |
| Settings window: Actions / General first render | 33 / 37 ms | 24 / 21 ms | Buttons, switch knobs and segmented knobs drew half-point blurred shadows, one offscreen pass each; they now draw an equivalent hairline. Remaining cost is card rasterization. |
| Settings window: HUD page, no layers | 108 ms | 81 ms | Preview faces drop the material, drop shadow and per-label shadows; the navigator and side panes use a flat tint instead of a material over the opaque window. |
| Settings window: HUD page, 12 layers | 360 ms | 173 ms | Each satellite face is one GPU raster (`drawingGroup`). Remaining cost is one full HUD layout per layer. |
| Settings window: Calibration tab (opened on demand) | 188 ms | 59 ms | The scope bar and calibration control show at once; the recognition cards lay out one frame later. |
| Voice/action registry build (`VoiceActionRegistry.make`, 600 apps) — every HUD open, MCP call and usage-tracker refresh | 60 ms | 0.6 ms | Base and finished lists cached per settings/applications/scope; record ids computed once instead of hashing JSON on every access. |
| MCP tool call round trip (`get_settings_summary`) | 62 ms | 0.7 ms | Same cache; the socket itself costs under 0.1 ms. `list_actions` 82 → 4 ms. |
| Launcher catalog per keystroke | rebuilt 966 rows + compared | reused | Catalog array rebuilt only when a snapshot arrives. |
| Sync after an edit | 5.4 ms on main | ~0 on main | Field encoding runs on a background task; only the snapshot copy stays on the main actor. |
| Timer alert glow (breathing, every screen) | 5.4% of a core | 0.2% | Blurred ring rasterized once on the GPU; the breathing is a Core Animation layer animation run by the render server, so the app does no per-frame work. |
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
- The Chrome tabs snapshot behind the tab HUD costs 45 ms of AppleScript plus
  ~370 ms of profile-history SQLite reads (`--only-chrome` shows the split).
  The HUD shows the previous snapshot at once, so this is not on the
  tab-switch path; enriching profiles after the tab list arrives would shorten
  the refresh.
