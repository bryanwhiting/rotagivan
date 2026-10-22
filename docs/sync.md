# Settings sync

Settings → Sync & backup. Rotagivan keeps the complete configuration (every
profile, HUD, action, macro and shortcut) in exactly one of two homes. Nothing
is written anywhere until you choose:

| | Cloud sync | Local file |
| --- | --- | --- |
| Where | Rotagivan's sync service, as ciphertext | `settings.yaml` in a folder you pick (default `~/.config/rotagivan`) |
| Encryption | AES-GCM under a key derived from your account password | none; the file is plain YAML you can read and edit |
| Other Macs | sign in with the same email and password | share the folder yourself (git, a synced drive) |
| API keys | inside the encrypted document, used on every Mac you sign in to | read from `~/.env`; never written to the file |
| Conflicts | whoever edited last wins, as a whole document | newer of file vs. this Mac wins; the loser goes to `backup/` |

Switch between them from the card's menu. Switching does not delete the other
copy.

## Cloud sync

**Keys.** Your password never leaves the Mac. PBKDF2-HMAC-SHA256 (600 000
rounds, salted with your email) turns it into a 256-bit master key. Two
subkeys are derived from that with HKDF:

- the *login secret* (64 hex characters) is what the server receives as the
  account password and hashes again with scrypt. A compromised server learns
  only this secret, which cannot be turned back into the master key;
- the *settings key* seals the document.

Any Mac that knows the email and password can decrypt. There is no device
approval, verification code or recovery code: the password is the recovery
code, and there is no reset. Keep it in a password manager.

Accounts created before 1.1.248 sent the real password to the server. The
first sign-in on this build logs in with it once and immediately changes the
server password to the login secret (`POST /v1/password`), so it is never sent
again.

**Document.** One JSON document: `{editedAt, editedBy, configuration, secrets}`,
sealed with AES-GCM; the associated data binds the account email and the
server revision, so the server cannot replay an old body under a new number.
Wire form: `rota-e2ee-settings-v1:` + base64(JSON `{version: 2, revision,
sealed}`). The prefix is the server's "encrypted" marker (it refuses to replace
an encrypted document with plaintext); the inner `version` is the format.

**Cycle.** `CloudSyncEngine.reconcile` (Rotagivan/CloudSync.swift) is a pure
function of (local document, persisted state, server) and is total: every run
ends in one of up-to-date, uploaded, downloaded, remote-won, local-won or
replaced-unreadable, or an error that is shown and retried.

1. Fingerprint the local configuration and API keys. If nothing changed since
   the last reconciliation and the trigger was a local edit, stop without
   touching the network.
2. Conditional `GET /v1/settings` with `If-None-Match: "<revision>"`; an idle
   poll is one small 304.
3. If the server has a newer document and this Mac has no unsynced edit, apply
   it. If both changed, compare the document's `editedAt` with the time of this
   Mac's first unsynced edit; the later one wins. A losing local state is kept
   as `sync.beforeMerge.<account>` in the encrypted preferences and a notice is
   shown.
4. Otherwise `PUT` with `baseRevision`; a 409 (another Mac wrote first) re-reads
   and tries again, up to four times.

A cloud copy this build cannot read (plaintext from a manual save, the former
field journal, or a different password) is replaced by this Mac's settings and
reported. A server returning a lower revision than this Mac already synced is
refused.

**Triggers.** Every edit uploads after 750 ms of quiet. Other Macs check
hourly, on wake, when the network returns, within a minute of using the HUD,
when the Sync pane opens, and on *Sync now* (also the HUD action of that name).
Failures retry after 60 s, doubling to 5 minutes.

**API keys.** OpenRouter and OpenAI keys pasted in the pane, or imported from
`~/.env`, are part of the document and are cached in this Mac's encrypted
preferences. Voice providers read `SyncSecrets.value(_:)`: the synced key in
cloud mode, otherwise `~/.env`.

## Local file

`settings.yaml` is the same format as Export file… (`AppConfiguration.yaml()`),
written atomically with mode 0600. After every edit the file is rewritten
within a second if its content changed. When the file changes on disk (an
editor, `git pull`, another Mac through a synced folder), the app loads it:
immediately through a folder watcher, and also on launch, wake, hourly and on
HUD use.

If the file changed on disk while this Mac was editing, the side with the later
timestamp wins and the other copy goes to `backup/settings-<time>.yaml`.

**Git.** If the folder contains `.git`, the pane shows the remote and two
switches:

- *Commit and push after each change* (default on): `git add settings.yaml`,
  commit, and push to the remote when one exists.
- *Pull on launch, on wake and hourly* (default on): `git pull --ff-only`. A
  diverged history is reported, never merged automatically.

*Initialize git repository* runs `git init` and writes a `.gitignore` for
`backup/` and `*.encrypted`. Add a remote yourself (`git remote add origin …`).
git runs non-interactively; a repository that needs credentials must have them
cached (SSH agent or the macOS credential helper).

## What stays on this Mac

The enable switch, launch-at-login, permissions, usage history and the
application index. Explicit exports are plain files; keep them private.

## Verification

```
zsh Rotagivan/test.sh      # includes the four suites below
```

- `SyncCryptoTests`: deterministic KDF, login-secret separation, authenticated
  envelope bound to account and revision, tamper/replay/version rejection,
  secrets routing by mode.
- `CloudSyncEngineTests`: first upload, idle 304, download, two-Mac edits,
  last-edit-wins both ways, CAS retry, rollback refusal, unreadable replacement.
- `LocalSyncTests`: private writes, change detection, conflict refusal with
  backups, a real git init/commit/push/pull round trip and divergence refusal.
- `SettingsSyncTests`: the coordinator against an in-memory server: mode gate,
  password-derived login, synced API keys, second-Mac download, wrong password,
  legacy account upgrade, sign-out, local-file write and reload.

Backend: `cd SyncBackend && npm run check && npx vitest run`.
