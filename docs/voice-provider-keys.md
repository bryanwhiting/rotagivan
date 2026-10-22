# Voice API keys

Voice providers read their API keys through `SyncSecrets.value(_:)`
(Rotagivan/SyncCrypto.swift):

- **Cloud sync** (Settings → Sync & backup → Cloud): the OpenRouter and OpenAI
  keys you paste into the API keys card, or import from `~/.env`, are part of
  the encrypted settings document and are available on every Mac you sign in
  to. They are cached in this Mac's encrypted preferences; nothing is written
  to YAML, logs or usage history.
- **Local file**, or no sync home chosen: keys are read from `~/.env`
  (`OPENROUTER_API_KEY`, `OPENAI_ROTA_KEY`) with a literal parser that never
  executes the file. They are never written to `settings.yaml`.

The pane shows whether each key is saved or found, never its value. Importing
from `~/.env` does not modify that file. See [sync.md](sync.md) for the
encryption.
