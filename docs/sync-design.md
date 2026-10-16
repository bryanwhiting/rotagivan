# Settings sync: audit and design

Status: branch `feature/sync-redesign`. This document records how sync worked
at 1.1.217 (219), why two Macs drifted or stalled, which patterns are kept,
and what changed. Security properties listed in `Rotagivan/VAULT.md` are
preserved; nothing here weakens them.

## 1. Audit of the 1.1.217 implementation

### 1.1 Keys

- One random 256-bit **vault master key** per account, created on the first Mac
  (`CredentialVault.save`, `VaultCrypto.randomMaster`). It never leaves the Mac
  except inside a grant or as the `RV1-…` recovery code the user copies.
- Stored in a device-only, non-synchronising Keychain item
  (`VaultKeychain.save`, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`).
- Purpose-separated subkeys via HKDF-SHA256: vault AES-GCM key, Ed25519
  signing seed (`VaultCrypto.derive/signing`), and the settings key
  (`SettingsCipherEnvelope.key`: salt = `accountID/vaultID`, info =
  `rota-settings-v1/cloud` or `/local`).
- Second Mac enrolment: X25519 device key, server relays only the public key and
  a signed grant (`VaultCrypto.grant/ungrant`); the user compares a 96-bit code
  shown on the requesting Mac (`VaultCrypto.code`). Or the recovery code.
- A separate random **local storage key** (`SettingsPersistence.localKey`)
  encrypts the on-disk SQLite preference row; it is never shared.

Verdict: sound. Kept unchanged.

### 1.2 Envelope and what the server sees

- Cloud settings are a field journal (`EncryptedSettingsJournal`) sealed with
  AES-GCM; AAD binds purpose, scope (`accountID/vaultID`) and the exact
  revision (`SettingsCipherEnvelope.seal`, `EncryptedSettingsCore.swift:17-33`).
  Wire form: `rota-e2ee-settings-v1:` + base64(JSON{version, revision, ciphertext})
  stored in the legacy `settings.yaml` column (`EncryptedAutoSync.encode`).
- Server (`SyncBackend/src/index.ts`) sees: email, scrypt hash, session-token
  hash, opaque ciphertext, revision, timestamps, device names/public keys, and
  grants. It refuses to replace an encrypted document with plaintext
  (`index.ts` PUT guard `NOT GLOB 'rota-e2ee-settings-v1:*'`).
- Writes are compare-and-swap on `baseRevision` (`index.ts` PUT `/v1/settings`).

Verdict: sound. Kept unchanged. (The vault record is additionally Ed25519
signed; the settings envelope relies on AEAD with the shared key, which is
equivalent for a two-party shared-key setting.)

### 1.3 Conflict handling

`SyncConfigurationCodec.fields` flattens the configuration into leaf paths
(dictionaries recurse, arrays are atomic, profiles keyed by ID). Each leaf
carries a Lamport stamp `(counter, deviceID)`; `EncryptedSettingsJournal.merge`
is per-field last-writer-wins with tombstones. A CAS race refetches and
re-merges (`EncryptedAutoSync.syncNow`).

Verdict: the right family of pattern (per-field LWW with logical clocks over
a settings document), but with a stall hazard, see 1.5.

### 1.4 Triggers (before)

`SettingsSync.start()` (`SettingsSync.swift:142-157` at 1.1.217):
- `store.objectWillChange` / `ShortcutSettings.objectWillChange` debounced
  750 ms → full cycle.
- A 30 s loop → full cycle.
- No wake, network or window-open trigger. No backoff.

Every cycle (`synchronizeAutomatically`, old lines 404-524) did: Keychain
restore wait → `vault.load()` (GET `/v1/vault`, verify signature, decrypt) →
GET `/v1/settings` (full 45 KB+ ciphertext, decrypt, merge) → possibly PUT.

### 1.5 Why two Macs did not stay in sync

1. **Enrolment was invisible.** A second Mac's sync status read "Unlock this
   Mac to download your settings and API keys" (old line 426) while the only
   way to proceed ("Approve from another Mac…", "Use recovery code…") lived in
   the *API keys* card, and nothing happened until that button was pressed.
   Until the grant exists `vault.settingsKey` is nil, so the Mac never
   downloads or uploads anything. This is the most likely reason the second
   Mac appeared to "not sync at all".
2. **Permanent stall after a delete/edit race.** Deleting a profile on Mac A
   writes ~60 tombstones; a later edit on Mac B of one field inside that
   profile can out-stamp its tombstone. The merged journal then rebuilds a
   profile fragment without `name`/`settings` and `AppConfiguration` decoding
   throws. `syncNow` validated *before* persisting and retried the identical
   merge every 30 s forever (`EncryptedAutoSync.swift:151-153` at 1.1.217), on
   every Mac that fetched it. Status: "Sync paused … error 1".
3. **Opaque errors.** `EncryptedSyncFailure`/`EncryptedSettingsError` had no
   `LocalizedError`, so the UI showed "The operation couldn't be completed.
   (Rotagivan.EncryptedSyncFailure error 2.)".
4. **Network chatter and rate limits.** `SettingsStore.foregroundBundleID`
   is `@Published` (`Models.swift:2648`), so every app switch fired
   `objectWillChange` → two network requests. With the 120 req/min/user limit
   (`index.ts` `limit(env, user:…, 120)`) a busy session could hit 429 and
   enter "Sync paused".
5. **No recovery from the rollback guard.** The guard
   (`EncryptedAutoSync.syncNow`, `remote.revision >= highestCloudRevision`)
   is correct, but after a legitimate server restore it stalls the Mac with
   no way out.
6. **Idle cost.** Each 30 s poll downloaded and decrypted the full document
   plus a vault GET, even when nothing changed.
7. **Wake/offline.** After sleep or a network drop the next attempt waited for
   the fixed 30 s loop, and failures never backed off.

Verified by probe (`scratchpad/roundtrip`): the real apply path
(`SettingsSync.applyUnbatched` → `SettingsStore`/`ShortcutSettings`) is a
fixed point of the field codec except a one-time `dragShortcut` resolution,
so ping-pong between Macs was *not* a cause.

## 2. Design (what is kept, what changed)

Principle: keep the vault, keys, envelope and CAS exactly as they are; fix
the control loop, the stall, and the enrolment UX. Favour the simplest thing
that is provably robust.

### 2.1 Key management (kept)

Random master key, device-held in Keychain, HKDF purpose separation, X25519
grants with a verification code, recovery code. The server never sees keys or
plaintext. See `VAULT.md`.

### 2.2 Envelope (kept)

Versioned (`version: 1`), AEAD, associated data = purpose + account/vault
scope + revision. Rollback protection = persisted `highestCloudRevision` and
the acknowledged-content check for an equal revision.

Addition: the transport may now report *unchanged* (HTTP 304) for an already
acknowledged **encrypted** revision. The actor accepts that only when the
reported revision equals its own acknowledged revision and no body came
with it; a server claiming "unchanged" for any other revision is rejected
(`EncryptedAutoSync.syncNow`, test "forged 304").

### 2.3 Versions / optimistic concurrency (kept, plus ETag)

`PUT /v1/settings {yaml, baseRevision}` → 409 on mismatch. `GET /v1/settings`
now returns `ETag: "<revision>"` and honours `If-None-Match` with a bodyless
304 (`SyncBackend/src/index.ts`). No schema migration.

### 2.4 Conflict resolution (kept, made total)

Per-field LWW with Lamport stamps and tombstones stays. Two additions make the
merge total (always yields a valid document):

- `SyncConfigurationCodec.configuration` drops a profile fragment that lacks
  `id`/`name`/`settings`/`shortcuts` — a deletion beats an orphan edit.
- If a merged journal still fails validation, `EncryptedAutoSync` adopts the
  cloud journal (it validated when its writer uploaded it) and returns
  `.synchronizedDroppingLocalConflict`. The discarded local stamps were never
  uploaded, so no other Mac can hold them and the peer's Lamport clock is a
  safe continuation. `SettingsSync` surfaces this as a one-line notice; the
  previous local state was already saved as an encrypted
  `encrypted.beforeMerge.<account>` snapshot.

Considered and rejected for now: re-keying the journal at "section"
granularity (one leaf per top-level setting). It removes more partial-structure
cases but needs a journal migration while both Macs may run different builds;
the two changes above already guarantee progress.

### 2.5 Triggers (changed)

- **Push:** any store change, debounced 750 ms, runs a cycle that first diffs
  portable fields against the last reconciled snapshot and returns without
  network when nothing portable changed (`SyncTrigger.localChange`).
- **Pull:** 30 s poll with a conditional GET. On failure the interval doubles
  to a 5 min cap and resets on success (`SettingsSync.pollDelay`).
- **Events:** launch, `NSWorkspace.didWakeNotification`, network path becoming
  satisfied (`NWPathMonitor`), opening the Sync settings pane, "Sync now".
- **Vault refresh:** every cycle while this Mac has no key (waiting for a
  grant); otherwise on event triggers or every 5 min (picks up new API keys and
  other Macs' approval requests).

Long-poll / Durable Object push was considered. It would cut pull latency
from ≤30 s to ~1 s at the cost of held Worker invocations and a second code
path; with two Macs and a human editing, 30 s plus event triggers is enough.
It can be added later behind the same `fetch(since:)` transport call.

### 2.6 Enrolment (changed)

A signed-in Mac without the key now registers its device key automatically
and shows the verification code in the Account & Sync card
(`VaultEnrollmentView`). The trusted Mac lists "Macs waiting for approval" in
the same card. Approval, grant unwrapping and the first download then happen
on the next poll without further clicks. Recovery-code entry remains
available on both the unenrolled and the Keychain-locked paths.

### 2.7 Rollback / replay

Unchanged: persisted revision floor, acknowledged-content equality for the
same revision, revision bound into AAD. New: `Re-sync from cloud…` (Privacy &
recovery) explicitly discards this Mac's journal for a wedged state; an
encrypted backup of the current settings is taken first.

### 2.8 Threat model

- **Malicious or compromised server:** sees ciphertext, device names, public
  keys and timing only. Cannot forge documents (AEAD with a key it lacks),
  cannot roll back silently (revision floor), cannot inject a device (grants
  are signed by the vault key and bound to recipient and account), cannot
  trick a client with a fake 304.
- **Stolen laptop, locked:** Keychain items are `WhenUnlockedThisDeviceOnly`;
  the SQLite preference row is ciphertext under a Keychain-held key.
- **Stolen laptop, unlocked / compromised Mac:** holds the master key.
  Revocation requires rotating the master key and re-granting; this is not
  implemented (see 3). Rotate API keys with providers.
- **Password compromise alone:** yields ciphertext only; cannot decrypt.

## 3. Not implemented (documented gaps)

- Device revocation / master-key rotation (needs a vault-identity rotation
  endpoint; today the server pins `vault_id`/`public_key`).
- Push notifications (long-poll) — see 2.5.
- Section-granularity journal re-keying — see 2.4.
- Email verification / password reset — unchanged from `SyncBackend/README.md`.

## 4. Verification

- `cd SyncBackend && npx vitest run` — adds the ETag/304 test.
- `zsh Rotagivan/test-encrypted-sync.sh` — core actor (conditional polls, forged
  304, invalid-merge fallback), codec (orphan profile fragment), integration
  (no-op local change costs no request, idle poll is one 304, backoff).
- `Rotagivan/test.sh` — full suite including `SyncCodecTests`.
