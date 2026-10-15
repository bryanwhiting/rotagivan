# Synced voice API keys

Open **Settings → General → Account & Sync → Encrypted API keys**. Sign in and,
if needed, explicitly **Unlock API keys**. Enter an OpenRouter key, an OpenAI key,
or both, then choose **Save & sync keys**. Blank fields preserve saved values.
The UI shows whether each provider is saved and unlocked without revealing keys.

On another updated Mac, sign into the same account and choose **Load synced keys**.
First-time devices still require approval from a trusted Mac (compare the code
directly) or your recovery code. Login alone cannot decrypt the vault. This uses
Rota's HTTPS vault service, not iCloud; the first Mac need not remain online after
approval. Key transfers are explicit; ordinary settings Save/Load is separate.

Both providers use the existing authenticated-encryption, signed, account-bound
vault. The service receives ciphertext, never plaintext provider keys. Device/root
key material stays in this Mac's device-only Keychain. Neither key is written to
settings YAML, activity history, logs, or repository files. Runtime voice requests
reuse the unlocked in-memory cache without prompting Keychain on every command.
An account switch or sign-out clears access to both providers.

OpenRouter/Jev reads only the OpenRouter slot. OpenAI Realtime/GPT Live reads only
the OpenAI slot, ahead of legacy environment configuration. Choose the provider in
**Voice mode → Voice provider**. Existing `OPENAI_ROTA_KEY` and `OPENROUTER_API_KEY`
environment setup remains a fallback, not automatic encrypted sync. Explicit
provider-specific imports are under **Recovery & advanced**. Importing does not
delete the original plaintext environment file; remove it yourself if no longer
needed. No real keys are imported or uploaded as part of building/testing this change.

Existing OpenRouter-only vaults remain readable. Adding an OpenAI key uses a
versioned encrypted provider map so older clients fail to decode instead of
silently discarding the extra provider. Update your Macs before loading that vault.
Saving on an out-of-date revision is rejected; load the newer copy before retrying.
Replacing one provider merges with the authenticated payload and preserves the
other. The change does not re-encrypt ordinary settings or make ordinary settings
sync automatic.

Tests use synthetic credentials and mocked vault transport/Keychain operations.
They cover both providers, independent replacement, OpenAI-only setup, legacy
decoding, encrypted transport, second-device approval/recovery, rollback and
stale-save rejection, account switching, cache routing, and native secure fields.
