# Encrypted API-key sync

In **General → Account & Sync → Encrypted API keys**, import/save on the first
Mac. On another Mac, sign into the same account and request access. Refresh on
the trusted Mac, approve by entering the code shown on the requesting Mac,
then load on the requesting Mac. Macs communicate through the server, not
directly, and need not be online simultaneously. No iCloud is used.

Save the recovery code in a safe password manager. It is used locally, never
uploaded. Losing every trusted Mac and this code makes the vault unrecoverable.
Transfers are explicit. Settings Save also saves an unlocked vault after the
settings save succeeds; confirmed cloud Load also loads the vault.

## Security boundaries

- Only API keys are end-to-end encrypted, not ordinary settings YAML. Keys
  never enter YAML or its backups. Device names, public keys and timestamps
  remain server-visible metadata.
- A random 256-bit master key derives separate AES-GCM and Ed25519 keys via
  HKDF-SHA256. Fresh nonces, signed ciphertext and associated data bind the
  account, vault and revision. Server writes use compare-and-swap revisions.
- Device approvals wrap the master key via ephemeral X25519, HKDF and AES-GCM,
  signed and bound to the account, vault and recipient. Compare the full
  96-bit verification code directly from the requesting Mac.
- Private material and cached ciphertext live in device-only, non-synchronizing
  macOS Keychain items using WhenUnlockedThisDeviceOnly. Existing devices pin
  vault identity and reject revisions below their highest seen revision. This
  is not a global freshness or transparency guarantee.
- HTTPS protects transport; the sync server cannot decrypt the vault. Local
  account login alone cannot decrypt an existing vault. The recovery code
  encodes the random master key, not the account password.
- OpenRouter still receives its API key over HTTPS when the app calls it.
  Import leaves the original user-managed plaintext ~/.env unchanged.
- Logout/password changes cannot erase master keys already learned by trusted
  Macs. Device revocation and vault-root rotation UI are not implemented.
  Treat a compromised trusted Mac as an API-key compromise and rotate the key
  with its provider. This implementation has not had an external audit.

Pending requests expire after seven days; accounts permit up to 20 devices.

## Verification

VaultCryptoTests covers crypto binding and recovery. CredentialVaultTests
covers two-Mac approval, stale saves, rollback, account switching, lost replies,
Keychain failures and UI rendering. Backend tests cover signature authorization,
isolation, CAS, malformed/plaintext fields and expired requests.

VaultLiveSmoke is an explicit production test with a disposable account and
synthetic key. It writes only the account ID/email to its cleanup receipt;
delete exactly that account afterward using both identifiers. It is not part
of routine tests and never uses the real user's API key.
