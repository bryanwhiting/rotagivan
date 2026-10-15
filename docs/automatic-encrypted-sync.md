# Automatic encrypted sync

Settings → Sync & backup → Account & Sync is the single entry point. Sign in, unlock
this Mac once if needed, and settings and API keys transfer automatically. Add
OpenRouter and/or OpenAI in the API keys card; blank fields preserve saved keys.
The app downloads existing keys without a separate Load operation. Failed saves
keep the entered key available for retry.

## Trust and storage

- The account vault master is shared only through verified device approval or a
  recovery code. Login alone never grants decryption access. No iCloud dependency.
- Settings use authenticated AES-GCM encryption with purpose-separated HKDF keys,
  binding ciphertext to the account, vault identity, and cloud revision.
- Provider keys retain the existing signed AES-GCM vault protocol. Schema 3 marks
  settings-enabled vaults, including accounts without any API keys. Older clients
  reject this payload instead of silently stripping providers or metadata.
- Cloud settings remain in the existing settings endpoint as opaque ciphertext.
  Conditional writes reject races. Once migrated, the server rejects plaintext
  writes from older builds. This is a compatibility guard, not a decryption key.
- Local preferences and sync journals live in an encrypted SQLite row under
  `~/Library/Application Support/Rotagivan/Settings/settings.sqlite`. The device's
  independent local-storage key stays in device-only login Keychain. SQLite
  journals contain ciphertext, never decoded settings. Directory/file permissions
  are 0700/0600. Unreadable data is never replaced with factory defaults.
- Existing app preferences migrate only after a verified encrypted save. Managed
  `~/.config/rotagivan/settings.yaml` and `backup/settings-*.yaml` snapshots become
  authenticated `.yaml.encrypted` archives; originals are removed only after
  reading back and verifying the encrypted copy. Explicit user exports and other
  apps' legacy preference domains are outside this migration.
- Screen Time history and application/browser indexes remain local and excluded
  from this sync. In-memory decrypted state is necessary while the app runs.

## Reconciliation

Local edits trigger a debounced transfer; idle Macs poll for remote changes.
Logical counters and stable per-Mac IDs make same-field concurrent updates
deterministic without depending on wall clocks. Independent scalar fields and
profiles merge separately; ordered lists remain atomic to preserve macro steps,
hotkey ordering, and HUD layout integrity. A CAS race triggers a fresh read and
merge, never an unconditional overwrite. Offline failures retain local settings
and retry. Invalid or tampered snapshots fail closed.

The first upgraded Mac retains its live settings while replacing the old manual
cloud snapshot with ciphertext. A newly connected Mac with an existing encrypted
cloud account downloads that account's settings; its previous configuration is
retained as an encrypted recovery snapshot. Update all Macs before relying on the
new sync format. Existing provider credentials and device trust are reused.

## Verification

Standalone tests cover authenticated encryption, wrong keys/accounts/purposes,
tamper/rollback rejection, local database durability, concurrent writers,
tombstones, retries, and account invalidation. Integration fixtures exercise
the real backend's acknowledgement shape, old manual-snapshot migration, new-Mac
download, independent edits, offline retry, and no plaintext transport or local
database data. Vault tests cover automatic preservation of another provider's
newer key. Backend tests reject plaintext downgrade after encryption is enabled.

Tests use synthetic data and injected transports/Keychain storage. They never
read real API keys, invoke voice providers, or copy actual user settings.

Run the focused regression suite with `zsh Rotagivan/test-encrypted-sync.sh`.
Backend validation uses `npm run check` and `npm test` in `SyncBackend`.

The account screen still requires Save keys after entering a new credential;
existing remote credentials load automatically. If a new key cannot upload, its
entry stays in the open form for retry. Explicit imports from `~/.env` never
delete the original environment file; remove an old plaintext key there yourself
if it is no longer needed by other tools.

Previously uploaded plaintext may remain in the hosting provider's historical
backups until their retention expires; replacing the live record cannot erase
those historical backups. Explicit exports remain readable by design.
