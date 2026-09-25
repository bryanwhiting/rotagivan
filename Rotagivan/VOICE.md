# Voice actions

Tap the microphone in the **Main HUD** (or make a single center tap) to enter voice mode. On first use, macOS asks for microphone access.

1. Say a short command, such as “Slack”, “open Slack”, or “pause music”.
2. Rotagivan stops recording after a short pause, or when you tap **Finish** / press Space or Enter. Recordings are capped at 12 seconds.
3. Jev ranks registered actions. The best match is at the top, second on the right, third at the bottom, and **Exit / Ignore** on the left.
4. Swipe or use arrow keys to select. **Space or Enter executes the selected action only after the final result is ready.** Releasing a swipe never executes it. Clicking an option selects it; the Run button is an alternative confirmation.
5. Escape / the close button returns to the regular HUD. Listen again starts a new utterance.

The transcript updates from short, coalesced audio uploads, not a true word-by-word streaming connection. While recording, Space/Enter finishes recording; wait for matching to finish before confirming an action.

## Models and credentials

- Transcription: `x-ai/grok-stt-1.0` via OpenRouter's `/api/v1/audio/transcriptions`.
- Matching: `typesafe/jev-1.13` via OpenRouter's `/api/alpha/decisions` Choice primitive.
- Prefer the locally unlocked Keychain vault, then fall back to `OPENROUTER_API_KEY` in the process environment or `~/.env`. The dotenv file is parsed as literal text, never executed. Keys never enter YAML, the app bundle, or logs. Optional [encrypted API-key sync](VAULT.md) uploads only client-encrypted ciphertext, separately from ordinary settings.

In **Actions → Voice action catalog**, you can inspect every registered action and its semantic description, including installed apps, macros, built-in commands and configured HUD actions. IDs are hashes of the local action's portable identity. Only locally registered, still-valid IDs can execute; Jev cannot return an arbitrary executable command or URL.

## Scores and large catalogs

Tile percentages are Jev's returned action probabilities, not normalized across the displayed three and not a guarantee that an action is correct. The separate Jev confidence measures the decision distribution. If **none** wins, confirmation is disabled for all action choices.

Jev allows 255 choices. Catalogs exceeding 254 actions are evaluated in batches (each includes none), then each batch's top three actions participate in one final decision. In this case the UI labels probabilities **Scores among finalists**. Every registered action is considered, but batching adds latency and is an approximation to a single full-catalog decision.

## Privacy and failure handling

- The microphone is opened only after explicit voice activation and permission.
- Audio goes over HTTPS to OpenRouter/xAI. Transcript and action names/descriptions go over HTTPS to Jev through OpenRouter.
- Rotagivan keeps audio and transcript in memory, not files, history, analytics, or synced settings. Provider-side retention is governed by the providers' policies and your account settings; this is not a promise of zero retention by the providers.
- Closing voice mode, dismissing the HUD, changing app/desktop, or sleeping cancels recording and pending work. Late results cannot execute.
- Network failures, denied permission, malformed scores, unknown IDs, no-match decisions and actions removed before confirmation fail closed.
- API keys in `~/.env` remain plaintext in that user-managed file; do not sync or commit it.

## Verification

`Rotagivan/Tests/VoiceTests.swift` covers literal credential parsing, ID allowlisting, score validation, no-match behavior, WAV encoding and recording limits, denied/cancelled permission, transcription-to-match flow with fake services, swipe selection, explicit keyboard confirmation, removed actions, and rendering. It does not use the real microphone.

An explicit `--live /path/to/synthetic.wav` test mode uses the configured key to transcribe synthetic speech and verify it maps to the registered Slack action. It does not execute the action.

Sources: [OpenRouter STT](https://openrouter.ai/docs/guides/overview/multimodal/stt), [OpenRouter Decisions API](https://openrouter.ai/docs/api/api-reference/alphadecisions/submit-a-decisions-request), [Jev Choice](https://docs.typesafe.ai/primitives/choice).

