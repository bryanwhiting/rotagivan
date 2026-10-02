# Production readiness: speed, Rust, paid sync, and cross-Mac reliability

Status: active implementation goal, not release approval.

Baseline app: **1.1.190 (192)**, commit `6626704`.
Unfinished local voice-note edits are preserved and excluded from this baseline.

## Requirements and evidence gates

- [ ] Optimize startup, HUD activation, voice preparation, Actions search, local indexing, pointer response, and sync latency.
  - Establish optimized-build p50/p95 measurements and cold/warm cases before and after each change.
  - Measure input-to-visible-HUD and gesture-to-frame timing on the installed app; CPU function timings alone do not prove perceived latency.
  - Include ordinary settings and the supported largest configuration, not just empty/default fixtures.
- [ ] Rewrite appropriate CPU/background components in Rust, and integrate them into the actual shipped app.
  - Use a bounded, versioned C ABI with explicit buffer ownership and error handling.
  - First targets: local browser/index search and bounded parsing; evaluate catalog normalization/search once measured.
  - Keep AppKit/SwiftUI UI, macOS permission handling, and system integration native.
  - Verify byte-compatible action IDs, Unicode matching, ordering, stale-result cancellation, and Swift/Rust parity before switching paths.
  - Package and sign the Rust artifact through the normal app build; benchmark shipping code, not an unused prototype.
  - Do not reimplement cryptographic primitives or migrate a native optimized operation merely to claim Rust adoption.
- [ ] Make animations smooth and interactions enjoyable.
  - Measure animation frame delivery and input latency during HUD navigation, bounce-back, voice waveform updates, and settings previews.
  - Isolate transient pointer/waveform updates from catalog building, icon I/O, and expensive view reconstruction.
  - Preserve partial-swipe control, forward-facing background HUDs, readable tiles, and stationary footer/status positioning.
  - Respect Reduce Motion; verify interrupted animations, rapid reversals, cancellation, and all navigation directions.
  - Use purposeful feedback for ready/listening, successful selection, unavailable destinations, and errors without adding artificial delays.
- [ ] Make settings and secret synchronization reliable and encrypted across Macs.
  - Settings currently remain plaintext YAML locally and server-side. The secrets vault is a separate encrypted protocol.
  - Implement a coordinated settings encryption/storage migration with backups and recovery, not encryption of exports alone.
  - Preserve manual Save/Load, timestamp/computer previews, compare-and-swap conflict protection, and last complete local state on failure.
  - Test interrupted uploads/downloads, simultaneous first saves, stale revisions, wrong accounts, token expiry, password rotation, invalid ciphertext, retries, and partial settings/vault failures.
  - Verify device enrollment and recovery with one trusted Mac offline; do not require iCloud.
  - Keep per-computer application paths, browser data, permission state, and enable switches local.
- [ ] Prepare paid cloud sync and a Stripe-backed customer/admin experience.
  - The local app must remain usable without a subscription or network access.
  - Add server-owned billing/customer mapping and cloud-sync entitlements; never trust a client-provided paid flag or a checkout redirect.
  - Add authenticated Checkout and customer-portal sessions using allowlisted server return URLs and Stripe secret credentials held only by the backend.
  - Verify bounded raw-body webhook signatures, event deduplication, retries, out-of-order delivery, authoritative subscription reconciliation, and cancellation/payment-failure behavior.
  - Keep account authentication/enrollment and recoverable data access separate from paid write entitlements; explicitly decide retention and download policy before charging customers.
  - Build a customer panel for subscription, saved-device status, and recovery instructions; a separately protected admin panel for operational state and audited support actions.
  - No plaintext user keys/settings in admin views, request logs, or billing metadata.
  - Test the complete lifecycle in Stripe test mode before any live provisioning. Price, billing interval, trial/grace period, and refund policy require product decisions.
- [ ] Make the project genuinely open source and distributable.
  - Choose an explicit license; there is no root license in the baseline tracked files.
  - Document free local features versus paid hosted sync, self-hosting boundaries, supported macOS/architectures, privacy, and contribution/build instructions.
  - Add reproducible Rust/native/backend build checks, signed/notarized downloads, update verification, release notes, and rollback instructions.
  - Verify clean install and upgrade without resetting Accessibility or weakening the persistent signing requirement.
- [ ] Verify every action family works.
  - Generate the action inventory from the registry and executable dispatchers; compare it with test coverage so new enum cases cannot silently escape verification.
  - Cover application activation, URLs/browser targeting, physical keystrokes, macros, media controls, macOS commands, window placement/management, HUD navigation/layers, pointer/gesture bindings, and voice activation.
  - Preserve app-scoped command revalidation, unknown/removed-action rejection, exactly-once execution, and safe preview/no-match behavior.
  - Distinguish mocked dispatch coverage from real macOS effects. System shortcuts depend on OS settings and permissions; shortcuts alone are not proof of successful execution.
  - Verify the last-two-app Side by Side and Swap Sides behavior on real windows, including minimized/full-screen/multi-display cases and unsupported apps.
- [ ] Verify seamless operation across physical computers.
  - Work/home fixtures must have different application paths, installed applications, browser profiles, keychain state, and permissions.
  - Transfer a saved profile and vocabulary; confirm matching by stable identities, graceful unavailable-app handling, and no foreign machine paths or permission overrides.
  - Exercise enrollment, offline use, reconnect, stale saves, account changes, recovery, and subscription changes from both machines.
  - Capture actual versions, settings revisions, and outcomes from both Macs. Two clients in one test process are not equivalent to this gate.

## Measured first bottleneck

Run from a clean checkout:

```sh
zsh Rotagivan/benchmark-actions.sh
```

This builds with `swiftc -O` and runs 12 timed samples after one warm-up for each
operation. Fixtures contain synthetic apps/macros only; they do not scan the
filesystem, load user preferences, access keys, post input events, or call providers.
The output is JSON. p95 here is a small-sample diagnostic, not a performance SLA.

Initial optimized measurements on this development Mac:

| Synthetic apps / macros | Audit median | Voice registry median | Actions rows median | Actions rows p95 |
| --- | ---: | ---: | ---: | ---: |
| 100 / 0 | 0.26 ms | 13.29 ms | 18.13 ms | 18.71 ms |
| 300 / 100 | 0.78 ms | 31.10 ms | 43.86 ms | 45.25 ms |
| 1000 / 500 | 3.51 ms | 105.94 ms | 170.71 ms | 180.12 ms |

Source evidence:

- `HotkeyOrganizerView.audit` and `dictionary` construct the audit and rows during view evaluation. Search/filter changes can trigger this work.
- `ActionTableRow.make` rebuilds `VoiceActionRegistry` and sorts rows; macro lookup is performed for each record.
- `VoiceActionRegistry.make` serializes settings into JSON, recursively visits objects, sorts records, and repeatedly evaluates SHA-derived IDs. Hex encoding uses per-byte formatted strings.
- `VoiceApplicationIndex` already scans off-main, coalesces scans, and preserves cached snapshots. Moving filesystem work off-main is not itself a new missing feature.

Next optimization: make the catalog an immutable, revision-keyed snapshot outside
view rendering; precompute IDs/search fields once, avoid unnecessary whole-settings
serialization, and filter the cached snapshot. Verify every invalidation input
(settings, shortcuts, app index, device/layer context, and vocabulary). Then measure
Rust/native alternatives for the remaining CPU/indexing work. Do not cache away
active-app scope checks or action execution validation.

No app-performance improvement is claimed by adding this benchmark.

## Sync/backend baseline

`npm test` in `SyncBackend` passed **10 tests** against the existing isolated Worker
runtime. Those tests cover account isolation/second-device login, password/session
handling, stale/racing settings writes, bounded input, encrypted vault signatures,
recipient-bound grants, and expiry. No production accounts or data were modified.

The baseline routes/migrations contain settings, accounts/sessions, and the secrets
vault, but no Stripe checkout, portal, webhook, subscription, or entitlement schema.
The existing native API rejects browser origins; a customer/admin web panel needs a
deliberate separate authentication/CSRF boundary, not a blanket relaxation of that
guard. Email verification, self-service password recovery, and account deletion
are also open release gates documented by `SyncBackend/README.md`.

The Cloudflare/Workers review skills guided this separation of provider-facing
backend concerns from client UI. This was an inventory and baseline test run, not
a completed security audit or production deployment.

## Implementation order

1. Land reproducible measurements and the full requirement/evidence inventory.
2. Remove catalog reconstruction from interactive rendering; verify latency and unchanged identities/scoping.
3. Integrate the Rust local index/search engine with bounded FFI, cancellation, parity tests, and packaging.
4. Complete encrypted settings migration and two-device fault/recovery tests.
5. Implement test-mode billing/entitlements and the customer/admin panel without gating the local app.
6. Audit every dispatcher and test real macOS effects; polish measured animations and input response.
7. Validate both physical Macs, clean installs/upgrades, licensing, notarization, and public distribution.

Work streams can advance independently where their interfaces are settled. A
missing Stripe account, license decision, or second test Mac must not prevent
local speed, safety, and test improvements. None of these streams is considered
complete merely because this inventory or one test suite passes.

## Provider contracts used for billing preparation

- [Stripe webhooks](https://docs.stripe.com/webhooks): raw-body verification, duplicate handling, retries, and non-guaranteed event order.
- [Stripe subscription overview](https://docs.stripe.com/billing/subscriptions/overview): server-side subscription lifecycle integration.
- [Stripe customer portal](https://docs.stripe.com/customer-management): hosted subscription management.
- [Cloudflare Workers best practices](https://developers.cloudflare.com/workers/best-practices/workers-best-practices/): provider/runtime-specific implementation review reference.

These references guide upcoming implementation; no Stripe integration is deployed
or claimed working yet.
