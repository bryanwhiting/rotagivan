# Rotagivan production release plan

Status: proposed feature plan for review  
Date: September 26, 2026

## Product direction

Turn Rotagivan into a production-ready, voice-driven Mac controller: one action catalog, one consistent HUD, reliable local search, and secure settings across computers.

Some pieces already exist. The checklist groups them into complete product experiences; unchecked items require implementation, integration, or release verification rather than necessarily being entirely new features.

## 1. Unified actions and application commands

- [ ] Make **Actions** the single place to manage actions, hotkeys, gestures, and application-specific behavior.
- [ ] Organize application actions as **Applications → Slack**, **Applications → Chrome**, etc., with application icons.
- [ ] Finish moving app overrides into Actions, then remove the separate **App overrides** sidebar item without losing existing assignments.
- [ ] Provide named, documented default commands for supported apps.
- [ ] Support user-created application commands:
  - Chrome: open a URL, history, bookmarks, or a numbered tab.
  - Slack: activity, threads, search, channels, and other shortcuts.
- [ ] Keep reserved action descriptions separate from editable keyword sets and example phrases.
- [ ] Make app-specific commands available to voice only in the appropriate app; recheck the app before execution.
- [ ] Make **Activate voice mode** a normal action assignable to a tap, hotkey, or HUD tile.

## 2. Voice as a first-class HUD experience

- [ ] Replace the voice modal/card with a proper HUD that looks and behaves like other HUD layers.
- [ ] Show live audio activity, transcription, processing status, and ranked action matches with scores.
- [ ] Use four directional tiles: best match, second match, third match, and cancel.
- [ ] Keep manual confirmation as the default; retain an explicit **Auto-decide** option.
- [ ] Add a setting to start listening automatically when the HUD opens.
- [ ] Create a dedicated **Voice mode** sidebar page and move all voice settings out of General.
- [ ] Reduce latency through streaming transcription, connection reuse, and incremental matching where supported.
- [ ] Verify whether Jev supports the desired streaming/WebSocket workflow; provide a responsive fallback if it doesn’t.
- [ ] Make microphone permissions, cancellation, timeouts, connection failures, and “no match” states clear and safe.

**Interpretation for review:** “Real-time TTS” appears to mean **real-time STT/transcription** here. Spoken responses would be a separate, optional feature.

## 3. Local indexing and browser intelligence

- [ ] Build a per-computer index of installed applications, bookmarks, and optionally browser history.
- [ ] Refresh efficiently at startup and when relevant data changes; add **Reindex now**, status, and error reporting.
- [ ] Keep machine-specific paths and browser data local; sync user preferences and action vocabulary separately.
- [ ] Make newly installed applications discoverable without restarting Rotagivan.
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
- [ ] Keep sync explicitly save/load driven, showing the saving computer and timestamp.
- [ ] Migrate existing data safely, with recovery and clear failure messages.

## 6. Settings and input cleanup

- [ ] Move **Calibration** under Actions and rename it **Tap calibration**.
- [ ] Remove pointer layers from Pointer & scrolling while preserving the effective pointer behavior.
- [ ] Redesign HUD settings around the selected, centered HUD with direct layer and tile editing.
- [ ] Separate **Invert picker direction** from **Invert two-finger HUD navigation**.
- [ ] Default inverted two-finger navigation on, applying inversion consistently to every direction—including diagonals.
- [ ] Refine pointer response for smoother low-speed movement and a gentler acceleration ramp, without adding noticeable lag.

## 7. Production release and distribution

- [ ] Choose and publish an explicit supported macOS version range.
- [ ] Complete first-run onboarding for permissions, voice credentials, privacy, and sync.
- [ ] Test clean installs, upgrades, migration, multiple Macs, and recovery from failures.
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

This document is a review checklist, not authorization to implement every item or a claim that release readiness has been verified.
