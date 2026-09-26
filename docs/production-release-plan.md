# Rotagivan production release plan

Status: implementation in progress; checked items have automated verification

Date: September 26, 2026

## Product direction

Turn Rotagivan into a production-ready, voice-driven Mac controller: one action catalog, one consistent HUD, reliable local search, and secure settings across computers.

Some pieces already exist. The checklist groups them into complete product experiences; unchecked items require implementation, integration, or release verification rather than necessarily being entirely new features.

## 1. Unified actions and application commands

- [ ] Make **Actions** the single place to manage actions, hotkeys, gestures, and application-specific behavior.
- [x] Organize application actions as **Applications → Slack**, **Applications → Chrome**, etc., with application icons.
- [x] Finish moving app overrides into Actions, then remove the separate **App overrides** sidebar item without losing existing assignments.
- [x] Provide named, documented default commands for supported apps (Chrome and Slack).
- [x] Support user-created application commands:
  - Chrome: open a URL, history, bookmarks, or a numbered tab.
  - Slack: activity, threads, search, channels, and other shortcuts.
- [x] Keep reserved action descriptions separate from editable keyword sets and example phrases.
- [x] Make app-specific commands available to voice only in the appropriate app; recheck the app before execution.
- [x] Make **Activate voice mode** a normal action assignable to a tap, hotkey, or HUD tile.

## 2. Voice as a first-class HUD experience

- [x] Replace the voice modal/card with a proper HUD that looks and behaves like other HUD layers.
- [x] Show live audio activity, transcription, processing status, and ranked action matches with scores.
- [x] Use four directional tiles: best match, second match, third match, and cancel.
- [x] Keep manual confirmation as the default; retain an explicit **Auto-decide** option.
- [x] Add a setting to start listening automatically when the HUD opens.
- [x] Create a dedicated **Voice mode** sidebar page and move all voice settings out of General.
- [ ] Reduce latency through streaming transcription, connection reuse, and incremental matching where supported.
- [x] Verify whether Jev supports the desired streaming/WebSocket workflow; provide a responsive fallback if it doesn’t.
  - [x] Review published provider contracts and define the supported architecture in [Voice streaming architecture](voice-streaming-architecture.md).
  - [x] Implement and verify the responsive fallback, preserving live candidate updates and prioritizing final speech. Native streaming remains a separate integration gate; no undocumented Jev WebSocket endpoint is assumed.
- [x] Make microphone permissions, cancellation, timeouts, connection failures, and “no match” states clear and safe.

**Interpretation for review:** “Real-time TTS” appears to mean **real-time STT/transcription** here. Spoken responses would be a separate, optional feature.

## 3. Local indexing and browser intelligence

- [ ] Build a per-computer index of installed applications, bookmarks, and optionally browser history.
- [ ] Refresh efficiently at startup and when relevant data changes; add **Reindex now**, status, and error reporting.
  - [x] Application startup warming and recursive change observation: focused checks, full regression, and installed verification passed in 1.1.181 (183). Browser indexing remains separate.
- [ ] Keep machine-specific paths and browser data local; sync user preferences and action vocabulary separately.
- [x] Make newly installed applications discoverable without restarting Rotagivan.
- [ ] Add Chrome recent/open-tab search and a **Recent tabs** HUD.
- [ ] When opening a bookmark or URL, focus an existing matching tab when possible instead of creating duplicates.
- [ ] Define browser-profile and URL-matching behavior so the wrong account or tab isn’t selected.
- [ ] Evaluate Rust for background indexing if its performance and packaging benefits justify it.

## 4. Browser memory and temporary notes

- [ ] Let users type or dictate a temporary note, such as “I’m working on the marketing campaign,” then review and explicitly save it.
  - OpenRouter transcription is allowed for dictation. Store the resulting note only in memory on this Mac; do not sync it or send it to Jev.
- [ ] Expire the note 30 minutes after saving; show its status and allow replacing or clearing it early.
- [ ] Keep notes entirely separate from action matching: saving, changing, clearing, or expiring a note must not change application choices, action ranking, confidence scores, or confirmation behavior.
- [ ] Offer opt-in browser-history indexing with retention controls and a clear delete function.
- [ ] Reuse the browser’s existing signed-in sessions when navigating.

**Privacy boundary for review:** Browser memory should not mean copying passwords, cookies, or login tokens. History backup, if wanted, should be a separate opt-in feature.

**Note voice-entry boundary:** Dictate note sends audio through the existing OpenRouter/xAI transcription path, not through Jev classification. Transcription fills a draft; it does not execute an action or save automatically. This supersedes the earlier on-device-only and intention-based ranking proposals. The saved note is simply a local, temporary note.

## 5. Encrypted settings and secrets

- [ ] Encrypt settings as well as secrets in transit and at rest.
- [ ] Separate local storage:
  - `~/.config/rota/settings`
  - `~/.config/rota/.secrets`
- [ ] Define these locations as encrypted storage; decrypt only locally when needed.
- [ ] Keep encryption keys out of those files, using protected local key storage.
- [ ] Preserve cross-Mac enrollment and recovery without requiring iCloud or both Macs to be online together.
- [x] Keep sync explicitly save/load driven, showing the saving computer and timestamp.
- [ ] Migrate existing data safely, with recovery and clear failure messages.

## 6. Settings and input cleanup

- [x] Move **Calibration** under Actions and rename it **Tap calibration**.
- [x] Remove pointer layers from Pointer & scrolling while preserving the effective pointer behavior.
- [x] Redesign HUD settings around the selected, centered HUD with direct layer and tile editing.
  - Replace the fixed 850-point preview inside the scrolling settings column with a workspace centered in the visible viewport.
  - Keep every layer reachable at narrow widths; retain shared rendering, tile popovers, drag/drop, and save paths.
  - Show Window Manager in the same workspace instead of adding a second editor below it.
  - Verify the actual settings page at normal and narrow window sizes, not only the standalone preview.
  - [x] Show clickable empty circles for vacant HUD positions. Clicking creates and selects a blank HUD in that position without moving existing layers; nearby circles fit the visible settings canvas, including the minimum window size.
- [x] Separate **Invert picker direction** from **Invert two-finger HUD navigation**.
- [x] Default inverted two-finger navigation on, applying inversion consistently to every direction—including diagonals.
- [ ] Refine pointer response for smoother low-speed movement and a gentler acceleration ramp, without adding noticeable lag.
  - Measure the shared response pipeline before changing defaults: low-speed pixel stepping, gain ramp, first-motion/reversal delay, stopping distance, and timing invariance.
  - Preserve deliberate user tuning. An optional preset alone does not complete the requested default-response improvement; verify the result on an installed device as well as synthetic replays.

## 7. Production release and distribution

- [ ] Choose and publish an explicit supported macOS version range.
- [ ] Complete first-run onboarding for permissions, voice credentials, privacy, and sync.
- [ ] Test clean installs, upgrades, migration, multiple Macs, and recovery from failures.
- [x] Fix the observed quit stall so updates can close the running app without a separate termination step.
  - The main-thread Keychain startup block was resolved in 1.1.178 (180) with nonblocking credential initialization and cancellation. Normal quit and reopening were verified; see the fourth-batch record below.
- [ ] Package a signed, notarized Mac download with a repeatable release process.
- [ ] Establish updates, version checks, release notes, and rollback/recovery.
- [ ] Build a landing page with a demo, requirements, download, privacy policy, and support contact.
- [ ] Start with a small external beta before a public release.
- [ ] Minimize ongoing release work through automated build, verification, and publishing steps.

## Suggested sequence

1. Consolidate Actions and settings.
2. Finish voice and HUD behavior.
3. Complete secure storage and local indexing.
4. Add browser intelligence.
5. Run an external beta and prepare public distribution.

## Verification record

The first production-plan batch is built and installed as **1.1.175 (177)**. The installed executable matches the certificate-pinned signed build, and the running process is under `/Applications/Rotagivan.app`. GPT-6 Sol agents implemented bounded tasks, followed by parent integration review and the repository regression suite.

- `ActionTableTests`: application groups, reserved descriptions, keyword sets, app scoping, and JSON/YAML preservation.
- `VoiceTests`, `ActionPickerTests`, `ActionBindingRuntimeTests`: reusable activation through keyboard, tap, and actual HUD tile selection; no duplicate recording; opt-in main-HUD auto-start; no auto-start on layer navigation or Window Manager; active-app revalidation; manual confirmation and cancellation.
- `VoiceApplicationIndexTests`, `ExplorerApplicationCatalogTests`: off-main scanning, coalescing, 60-second freshness, explicit refresh, removals, error recovery, and immediate cached return during a blocked background scan. First indexing still waits for the initial snapshot; filesystem event watching and browser indexing remain open.
- `ReleaseSettingsTests`: rendered native navigation and actual Auto-decide control activation; legacy routes; calibration and empty/disabled app override access. Tests use isolated settings and do not start microphone input or cloud sync.
- Existing pointer, trackpad, gesture, macro, HUD, configuration, cryptography, and manual-sync regression stages passed. A pre-existing media-tile test fixture was corrected to intercept the intended media dispatcher and verify its keep-open behavior rather than sending real media keys.

### Second batch: voice HUD and input-settings cleanup

Version **1.1.176 (178)** adds a four-sector voice HUD using the same sector geometry, chrome, focus treatment, and themes as the main HUD. Transcript, waveform, and status have fixed positions; an equatable wheel separates static rendering from waveform-only updates. It introduces no new animation or input timer. Manual confirmation remains the default.

Built, installed with `./launch.sh --keep-accessibility`, and reopened under `/Applications/Rotagivan.app`. Installed and built executable SHA-256 match (`5ab985c9b626ba4e58591848c1cf61ead046ac066ac5d9f9481c3ec29a028c0e`); the existing certificate-pinned signature verifies. The old process stalled on normal quit and required scoped termination; that release issue remains open. Accessibility permissions and signing trust were not reset.

- `VoiceHUDUISmoke`: 48 native renders across three themes, light/dark appearance, and eight voice states; long text, native tile selection without execution, stable center, confirmation, cancellation, retry, and forced opaque presentation. Representative screenshots were visually reviewed. Synthetic microphone and cloud fixtures only.
- `AppExplorerTests`, `HUDMapTests`, `ConfigurationTests`: independent picker/navigation preferences; all directions, capacities 2–16, deep-fan continuity, legacy defaults, and JSON/YAML round-trips. Two-finger navigation defaults to inverted; the separate picker preference defaults to regular to preserve existing selection behavior. Explicit custom gesture-to-action assignments keep their literal meaning.
- `ActionBindingRuntimeTests`: controller-level inverted selection, repeated media selections after input resets, and all four voice directions across lift resets without execution.
- `ReleaseSettingsTests`: pointer-layer controls are absent from current and legacy routes while device motion controls, saved profiles, effective pointer settings, and shortcuts remain intact.
- All regression stages passed. An early run was interrupted when visual fixes changed a source during compilation; all affected UI/controller/configuration/sync stages were rerun against frozen sources and passed. Final UI artifacts: `/private/tmp/rotagivan-ui-tests.X9Glh3`.

### Third batch: application commands

Adds a shared application-command editor in Actions: create, edit, disable, and delete named shortcuts or app-targeted HTTP(S) URLs. Stable command IDs preserve learned keyword sets when names or outputs change. Defaults can be duplicated into editable custom commands. The existing shortcut recorder, application icons, cached application index, and action executor are reused.

- Chrome provides 17 named defaults, alongside the existing Slack defaults. Key mappings were checked against the official [Chrome](https://support.google.com/chrome/answer/157179?hl=en) and [Slack](https://slack.com/help/articles/201374536-Slack-keyboard-shortcuts) documentation. These are physical English-layout output shortcuts, not global hotkey registrations.
- Native UI fixtures cover the actual Actions-menu entry, create/edit/disable, cancellation, confirmed deletion, shortcut recording, missing apps, invalid URLs, and capacity limits. Tests use isolated settings; nothing is executed when saving.
- Voice confirmation revalidates the selected command's current output, app scope, and enabled state. Edited, removed, disabled, or wrong-app matches cannot execute a stale selection.
- Explicit URL targets use a shared dispatcher and never silently fall back to the default browser. Fixtures cover keyboard, gesture, and HUD routes, missing/wrong targets, and launch failures without launching real applications. Generic URLs retain their existing default-browser behavior.
- Exact character-set reuse in shared URL/app-ID validation reduced the optimized fixture benchmark from 226.7 ms to 24.7 ms per catalog at 500 commands (five runs, 32 application fixtures and learned vocabulary). Validation equivalence covers 270 bundle IDs and 274 URLs. This measures catalog construction, not end-to-end provider latency or rendered frame time.
- The complete suite passed again against frozen final sources, including native Actions/Voice/settings UI, input routing, configuration, storage, and manual sync. Test artifacts: `/private/tmp/rotagivan-tests.RuoyZU`.
- **1.1.177 (179)** was built, installed with `./launch.sh --keep-accessibility`, and reopened from `/Applications/Rotagivan.app`. Built and installed SHA-256 match (`9fbb9bd6e3a020c156c6129eec383c59e7f5c902ef2155ddac083ac8cf7e79ae`), and the persistent certificate-pinned signature verifies. The old process required scoped termination after its Keychain-blocked startup was sampled; no Accessibility or signing-trust reset occurred.
- **Runtime limitation observed in this batch:** a three-second sample of the reopened 1.1.177 (179) process found the same synchronous Keychain startup block. Installation and automated verification completed, but interactive usability was not established. The fourth batch below resolves the main-thread block; no Keychain prompt or trust setting was changed to bypass it.

### Fourth batch: nonblocking credentials

The startup/quit investigation found synchronous Keychain access on the main thread. Saved-login restoration, vault hydration/persistence, and voice-key preparation now use one shared off-main credential worker. It admits one Security operation at a time and rejects additional requests instead of accumulating blocked calls. Cancelling a caller does not pretend to cancel an already-running Security operation or release its occupied slot.

- Pending credentials have explicit loading states. Save/Load cannot silently switch to local-only behavior while the saved account is unknown; failed reads offer explicit retry without automatic transfers or retry loops.
- Account/operation generations discard stale results after account changes, cancellation, or shutdown. Quit does not wait for a blocked Keychain read. Voice cannot request microphone permission or begin recording from a cancelled credential preparation.
- Vault recovery remains available after a terminal cached-read failure, but not during a pending read. A valid recovery code and verified remote record are required before writing replacement local key material.
- Keychain services, item queries, accessibility/protection flags, encryption formats, and signing trust are unchanged. No real credential values, microphone input, cloud accounts, or live Keychain reads are used by the new regression fixtures.
- Focused worker, sync, vault, voice, and native loading/retry checks passed, followed by the complete final-source regression suite. Artifacts: `/private/tmp/rotagivan-tests.xSKL5c`. Native fixtures exercise actual Retry controls and distinguish unknown account state from missing keys; captures were visually reviewed. Late credential-write success and failure after quit are also covered.
- **1.1.178 (180)** was built, installed with `./launch.sh --keep-accessibility`, and reopened from `/Applications/Rotagivan.app`. Built/installed executable SHA-256 matches (`61d6ae9fd0cb3864c88e5324482fefded3ee2f3bb1688ddecd1f4639d7c4e852`), with the existing certificate-pinned signature verified independently.
- Installed startup and reopened-process samples show normal AppKit main-thread event-loop activity, with the pending Keychain read confined to `local.rotagivan.credentials`. Normal quit completed immediately without forced termination, and reopening succeeded. Only the old, already-blocked 1.1.177 process needed scoped termination during installation. Accessibility, Keychain trust, and settings were not reset.
- Keychain authorization itself may still be pending; this does not claim that credentials were successfully unlocked or that live cloud/voice requests were exercised. The verified fix is that pending credential access no longer freezes the app or prevents normal quit.

### Fifth batch: centered HUD settings workspace

The selected HUD now stays centered in a bounded, resizable settings workspace instead of a fixed-height preview inside the page scroll view. Surrounding HUDs remain clickable; a layer rail and picker keep every saved layer reachable, including legacy overflow layers. Default tap controls remain available in a native sheet.

- Window Manager uses one editable canvas with its own layout selector and the existing window-scoped save path. Tile popovers, nested navigation, drag/drop, templates, action assignments, and theme/options controls reuse existing components.
- Settings default to 940 × 740 with an 860 × 680 minimum and can expand. Other pages preserve their original top alignment and gain horizontal scrolling when needed at narrow widths.
- `HUDWorkspaceUISmoke` verifies the actual `ContentView` in native windows at 860 × 680, 940 × 740, and 1240 × 900. It measures the real viewport anchor and rendered tile bounds, checks exactly one canvas, browses mapped/overflow layers without changing settings, and exercises selected-layer renaming, root/nested dragging, native popovers, default-tap dismissal, and Window Manager-only persistence.
- All three themes were rendered at the minimum size and visually reviewed. Settings-only presentation keeps the selected card fully visible and prevents satellite content showing through the native theme. Live HUD orbit geometry, tile dimensions, input routing, and animation behavior remain unchanged; no new input timer or background polling was introduced.
- The complete regression suite passed, including the new workspace test and existing HUD preview/reserved-sheet checks now included in `Rotagivan/test.sh`. Final artifacts: `/private/tmp/rotagivan-tests.SUfOvx`. An earlier run stopped on disk exhaustion; only obsolete, rebuildable test executables from completed runs were removed, preserving source and screenshots, before the successful rerun.
- **1.1.179 (181)** was built, installed using `./launch.sh --keep-accessibility`, and reopened from `/Applications/Rotagivan.app`. Built/installed executable SHA-256 matches (`1e5333724e7326d4c6743764fe9433e7113eb527aadb68ff490e4a3797bcd479`), and the existing certificate-pinned signature verifies. Normal quit completed without forced termination; reopening showed a normal AppKit main-thread event loop, with pending Keychain work confined to the background worker. Accessibility permissions and signing trust were preserved.
- Verification boundary: resizing was exercised through native windows hosting the actual settings page. External automation of the installed window was unavailable because the tool host lacks Accessibility access; no new grant was requested. Public-release and cross-Mac gates remain open.

### Sixth batch: responsive voice fallback and lifecycle safety

Final audio now cancels superseded preview work immediately, then starts its final transcription/classification as soon as the admitted request actually completes cancellation. One shared admission gate spans replacement HUD sessions, so retry cannot overlap an old request that is still stopping. A monotonic 15-second final-processing budget covers cancellation drain, transcription, and every Jev batch; this is a failure deadline, not a guarantee of provider response time.

- Live provisional candidates remain available while speaking. Pending snapshots coalesce, completed previews still advance, and identical successfully classified partial text avoids redundant Jev calls. Final text is always classified again. The existing URLSession remains usable after preview cancellation; closing the voice session rejects future requests.
- Failure and cancellation revoke pending credential/permission preparation, stop microphone input, clear executable results, and reject late success/error callbacks. A committed final decision cannot be replaced by a late preview or duplicate final. Admission is released before final callbacks, preserving existing opt-in Auto-decide behavior without a false busy state.
- The controller reuses the action registry to validate the captured catalog, vocabulary, descriptions, and active application at response boundaries. Final execution still rechecks the selected action's current output, scope, and enabled state. No catalog scan was added to the waveform/render loop. The existing HUD renderer, manual-confirmation default, credential storage, and provider/model selection are unchanged.
- `VoiceTests` adds deterministic gated transport and monotonic-clock coverage for final priority, cancellation acknowledgement, cross-session retries, overall deadlines, delayed timer delivery, no-speech/silence/recording endpoints, stale preparation/results, immutable finals, catalog changes, provisional progress, and repeated-transcript suppression. Synthetic microphone/cloud fixtures only.
- New `VoiceTransportTests` intercepts every URL offline and exercises the actual OpenRouter URLSession implementation: cancellation acknowledgement, overlapping-request rejection, HTTP session reuse, permanent close, STT request shape, and 300-action Jev batching/cancellation. No real key, socket, or provider inference is used.
- Native voice UI tests render 54 states across three themes and both appearances, including actual fixture connection failure, Retry, and absence of executable stale candidates. Representative error, timeout, and ready captures were visually reviewed. Focused artifacts: `/private/tmp/rotagivan-voice-lifecycle.CGRLyc`.
- The complete frozen-source regression suite passed, including gesture/pointer routing, Actions, configuration and sync, credentials, and the centered HUD workspace. Final artifacts: `/private/tmp/rotagivan-tests.YEpS5N`. Obsolete test executables from completed earlier runs were removed to recover space; screenshots and source were preserved.
- **1.1.180 (182)** was built, installed using `./launch.sh --keep-accessibility`, and reopened from `/Applications/Rotagivan.app`. Built/installed executable SHA-256 matches (`2593d90081f2d22faaafbe0b5164f6ec56e1b0ebaa49ec032665557c48fbd538`), with the persistent certificate-pinned signature verified independently. Normal quit and reopening succeeded without force termination. Installed/reopened samples show a normal AppKit main-thread event loop; pending Keychain work remains on the background credential worker. No Accessibility or signing-trust reset occurred.
- Native audio streaming remains unimplemented. This release uses bounded OpenRouter WAV snapshots and complete Jev decisions; it does not invent a Jev WebSocket API, switch providers, or claim measured live-network latency. Live microphone authorization, provider access, and cross-Mac/public-release gates remain separate verification work.

### Seventh batch: automatic application discovery

The per-computer application index now warms at startup independently of settings-window presentation. Recursive filesystem notifications request debounced background refreshes; Voice, Actions, the action picker, and the HUD destination picker share the same complete snapshot. No application-root scans or polling timers were added to rendering. The cache remains local and in memory; browser bookmarks, history, and open tabs are not part of this batch.

- One physical scan stays admitted until it returns, with one pending invalidation. Stop/restart generations discard late results and callbacks without overlapping the old scan. Cached reads remain immediate during refresh, failed scans preserve the last complete catalog, and watcher failures have separate visible status from scan failures.
- Native fixtures cover initially absent application roots, nested installs, atomic replacement, removals, unrelated-parent filtering, stop/restart, and symlink-root retargeting. Physical filesystem spellings are resolved off-main with POSIX `realpath`; event filtering uses strings without per-event filesystem resolution. Three consecutive native runs passed, followed by a final recompiled pass after the metadata compatibility fix.
- Fresh, bounded property-list reads avoid Foundation's stale same-path bundle cache. Catalog fixtures cover localized names, flat bundles, corrupt/oversized metadata, regular-file metadata symlinks, explicit root symlinks, and existing duplicate/helper/descendant-symlink filtering.
- Remembered-path and targeted-browser validation use the same fresh identity parser without enumerating localized resource directories. Localized names are loaded only for full catalog entries and explicit app selection. An initial regression run was deliberately interrupted to make this hot-path correction; only its rebuildable executables were removed to recover disk space, preserving captures and source. The complete suite subsequently passed against the final frozen source.
- The new native shared-picker fixture proves one initial scan across both open pickers, live snapshot replacement, removal of old rows, and scan-free native searching. Final captures were visually reviewed. Focused artifacts: `/private/tmp/rotagivan-index-lifecycle.n34MwU` and `/private/tmp/rotagivan-shared-pickers.qzJMFs`. Fixtures use synthetic applications and isolated temporary directories, not browser data, credentials, or provider calls.
- The complete regression suite passed, including native shared-picker replacement, input routing, voice, configuration, credentials, sync, and settings/workspace checks. Final artifacts: `/private/tmp/rotagivan-tests.B4uUvS`. Shared-picker captures from this final run were visually reviewed; the source fingerprint remained unchanged through verification and build.
- **1.1.181 (183)** was built, installed using `./launch.sh --keep-accessibility`, and reopened from `/Applications/Rotagivan.app`. Built/installed executable SHA-256 matches (`9e9ea7680c6505fef6f97101786de13b6ab7629274f068e7cbcbb5248ebc343c`), with the persistent certificate-pinned signature independently verified. Normal quit and reopening succeeded without forced termination. Both installed-process samples show a normal AppKit main-thread event loop, with pending Keychain work confined to the background credential worker. Accessibility and signing trust were preserved. This does not claim successful credential unlocking, live provider testing, browser indexing, or cross-Mac/public-release readiness.

### Remaining implementation boundaries

- Temporary notes are being implemented as memory-only, 30-minute notes with shared Voice settings/HUD controls. The user explicitly permits OpenRouter transcription, but notes must never influence app/action choices or be sent to Jev. Dictation is a separate transcription-only flow with explicit review and save. Opening the note editor stops action voice capture and prevents it restarting while editing. Earlier intention/on-device draft checks are superseded; the new note-only implementation still needs final verification. These unfinished local changes are excluded from the HUD-circle release, 1.1.183 (185).
- Application commands support named physical shortcuts and explicitly app-targeted HTTP(S) URLs. Browser-profile selection, existing-tab reuse, and browser-history indexing remain unfinished. The chosen application currently decides which window/profile receives a URL.
- The secrets vault is encrypted, but settings encryption remains unfinished: local YAML/backups, settings in UserDefaults, and remote settings storage require coordinated migration. Encrypting only an export would not complete this feature.

Run `zsh Rotagivan/test.sh` to reproduce the suite. A passing local suite is not a claim of cross-Mac validation, provider latency guarantees, notarization, or public-release readiness. Those gates remain unchecked.

This document tracks reviewed implementation and remaining release work; unchecked items are not claimed complete.

### HUD empty-position follow-up — 1.1.183 (185)

- Vacant settings-map positions show empty plus circles. Clicking creates a blank HUD at that exact position, saves it, and selects it for tile editing. Existing explicit and legacy positions are preserved; occupied positions cannot be overwritten by stale clicks.
- Nearby add controls fit the visible viewport without resizing the selected HUD. Cardinal gaps use compact plus circles when space is tight. Live HUD rendering/navigation is unchanged.
- Focused map, template, settings, layout-preview, and native workspace checks passed. Native mouse tests filled all eight positions at the minimum window size; screenshot review verified fully visible corner circles. Captures: `/private/tmp/rotagivan-hud-empty-circles/Rotagivan/build/hud-verification`.
- Built, installed with `./launch.sh --keep-accessibility`, and reopened from `/Applications/Rotagivan.app`. Persistent certificate-pinned signing verified; built/installed executable SHA-256 matches `cda84f90492af7856389e9f1d8113e859f2740c73a4bb3c21747432ac7f68c74`. Compiled sources were unchanged during the build. Unfinished voice-note work was isolated from this release. This was focused HUD verification, not a fresh run of the entire regression suite.
