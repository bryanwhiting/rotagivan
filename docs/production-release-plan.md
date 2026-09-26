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
- [ ] Provide named, documented default commands for supported apps.
- [ ] Support user-created application commands:
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
- [ ] Verify whether Jev supports the desired streaming/WebSocket workflow; provide a responsive fallback if it doesn’t.
- [ ] Make microphone permissions, cancellation, timeouts, connection failures, and “no match” states clear and safe.

**Interpretation for review:** “Real-time TTS” appears to mean **real-time STT/transcription** here. Spoken responses would be a separate, optional feature.

## 3. Local indexing and browser intelligence

- [ ] Build a per-computer index of installed applications, bookmarks, and optionally browser history.
- [ ] Refresh efficiently at startup and when relevant data changes; add **Reindex now**, status, and error reporting.
- [ ] Keep machine-specific paths and browser data local; sync user preferences and action vocabulary separately.
- [x] Make newly installed applications discoverable without restarting Rotagivan.
- [ ] Add Chrome recent/open-tab search and a **Recent tabs** HUD.
- [ ] When opening a bookmark or URL, focus an existing matching tab when possible instead of creating duplicates.
- [ ] Define browser-profile and URL-matching behavior so the wrong account or tab isn’t selected.
- [ ] Evaluate Rust for background indexing if its performance and packaging benefits justify it.

## 4. Memory and temporary intent

- [ ] Let users set a temporary intention, such as “I’m working on the marketing campaign.”
- [ ] Expire that intention after 30 minutes; show its status and allow clearing it early.
- [ ] Use intention to improve ranking—not to bypass action scope or confirmation.
- [ ] Offer opt-in browser-history indexing with retention controls and a clear delete function.
- [ ] Reuse the browser’s existing signed-in sessions when navigating.

**Privacy boundary for review:** Browser memory should not mean copying passwords, cookies, or login tokens. History backup, if wanted, should be a separate opt-in feature.

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
- [ ] Redesign HUD settings around the selected, centered HUD with direct layer and tile editing.
- [x] Separate **Invert picker direction** from **Invert two-finger HUD navigation**.
- [x] Default inverted two-finger navigation on, applying inversion consistently to every direction—including diagonals.
- [ ] Refine pointer response for smoother low-speed movement and a gentler acceleration ramp, without adding noticeable lag.

## 7. Production release and distribution

- [ ] Choose and publish an explicit supported macOS version range.
- [ ] Complete first-run onboarding for permissions, voice credentials, privacy, and sync.
- [ ] Test clean installs, upgrades, migration, multiple Macs, and recovery from failures.
- [ ] Fix the observed quit stall so updates can close the running app without a separate termination step.
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

### Remaining implementation boundaries

- Application subgroups exist, but a complete named application-command authoring workflow and Chrome defaults remain unfinished. Browser-targeted URL actions must not silently use a different default browser.
- The secrets vault is encrypted, but settings encryption remains unfinished: local YAML/backups, settings in UserDefaults, and remote settings storage require coordinated migration. Encrypting only an export would not complete this feature.

Run `zsh Rotagivan/test.sh` to reproduce the suite. A passing local suite is not a claim of cross-Mac validation, provider latency guarantees, notarization, or public-release readiness. Those gates remain unchecked.

This document tracks reviewed implementation and remaining release work; unchecked items are not claimed complete.
