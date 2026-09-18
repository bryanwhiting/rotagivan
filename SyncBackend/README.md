# Rotagivan account sync

Production API: `https://rotagivan-sync.bryan-b4b.workers.dev`

Cloudflare Worker `rotagivan-sync` owns a dedicated D1 database of the same name.
The macOS app never receives a Cloudflare administrative token. It talks to the
Worker over HTTPS with a revocable, 30-day session token kept in macOS Keychain.
Database queries derive the user ID from that session, never from request data.

## Authentication and limits

- Email/password registration and login; email is normalized, passwords are not.
- Passwords: 12+ characters, at most 1024 UTF-8 bytes; a fresh 128-bit salt per
  password and native `node:crypto` scrypt (N=16384, r=8, p=5, 32-byte output).
  The `scrypt-v1` prefix identifies these fixed parameters for future upgrades.
  This follows an [OWASP-listed scrypt configuration](https://cheatsheetseries.owasp.org/cheatsheets/Password_Storage_Cheat_Sheet.html#scrypt)
  using [Workers' native crypto support](https://developers.cloudflare.com/workers/runtime-apis/nodejs/crypto/).
- Session tokens are 256 random bits; only their SHA-256 hashes are in D1.
  Auth-version checks prevent an in-flight old-password login from bypassing a
  password change. Changing passwords revokes the old device sessions.
- Per-location native rate limiting plus atomic D1 limits per email and IP;
  authenticated requests are limited per user. Expired records are pruned daily.
- Bounded JSON/YAML payloads, prepared statements, generic authentication errors,
  no CORS/cookie authentication, no credential/body logging, no-store responses.
- Settings are access-controlled, **not end-to-end encrypted**. The service
  operator can access D1. Never put secrets in a profile name or YAML field.

Email verification, email-based password recovery, MFA, and account deletion UI
are not implemented. Email is a login identifier, **not proof of mailbox
ownership**. There is no password-reset endpoint that trusts an unverified email.
Use a password manager. This is a small app backend, not an audited identity
provider; review it before a broader public launch.

## API

| Method / path | Request | Result |
| --- | --- | --- |
| POST `/v1/register` | email, password | token, userID, email, expiresAt |
| POST `/v1/login` | email, password | same session fields |
| POST `/v1/logout` | Bearer token | revokes this token |
| POST `/v1/password` | Bearer token, currentPassword, newPassword | replacement session; others revoked |
| GET `/v1/settings` | Bearer token | yaml, revision, updatedAt; null YAML/revision 0 if empty |
| PUT `/v1/settings` | Bearer token, yaml, baseRevision | new revision; 409 if stale |

YAML is stored as bounded opaque configuration data; the app validates the full
schema before upload and before application. Malformed/unsupported remote YAML
never replaces local settings. Request body fields cannot select another user.
Atomic conditional writes prevent lost updates, including racing first uploads.

## Development and deployment

Requires Node 22+, npm, and your Cloudflare account ID/token in `~/.env`.
`scripts/cloudflare.mjs` parses that file without executing shell statements and
passes only the selected Cloudflare credentials to Wrangler; it never prints them.
Supported names: `CF_ACCOUNT_ID` / `CLOUDFLARE_ACCOUNT_ID` and
`CF_API_TOKEN_ACCOUNT` / `CF_API_TOKEN_USER` / `CLOUDFLARE_API_TOKEN`.

```sh
cd SyncBackend
npm ci --legacy-peer-deps
npm run check
npm test
node scripts/cloudflare.mjs deploy --dry-run
node scripts/cloudflare.mjs d1 migrations apply rotagivan-sync --remote
npm run deploy
```

Cloudflare's Vitest pool requires Vitest 4, not Vitest 5. The pool's bundled
Wrangler/Miniflare are overridden to the current patched runtime so tests support
the production compatibility date and avoid the older image-library advisory.
`npm audit` was clean when implemented. Generated `Env` comes from Wrangler.

The optional live test creates two disposable accounts, checks second-device
login, exact YAML roundtrip, isolation, CAS conflicts and logout, then deletes only
those accounts (including their sessions/settings through foreign-key cascades):

```sh
node scripts/smoke.mjs https://rotagivan-sync.bryan-b4b.workers.dev
```

No real account is provisioned by deployment. Create yours in the macOS UI.
Cloudflare usage is billed to the account whose credentials deploy this service.
