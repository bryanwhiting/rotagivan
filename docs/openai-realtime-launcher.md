# OpenAI Realtime launcher

Select **OpenAI Realtime · live speech to text** in Settings → Voice mode → Voice provider. The preference is local to this Mac. Existing OpenRouter/Jev voice remains the default. Invoke the existing App Explorer/voice hotkey or gesture; this is not the Settings window startup. Live transcript fragments update the same Rust search used by typing. Say an app/action name, use arrows, then Return. Apps and opening Rotagivan settings need one Return; menu and registered Mac actions need a second distinct Return. Holding Return cannot confirm. No partial/final speech automatically executes anything, even if the existing Jev Auto-decide option is enabled.

## Provider and protocol

Current official [Realtime transcription documentation](https://developers.openai.com/api/docs/guides/realtime-transcription) recommends **gpt-live-transcribe** for incremental speech-to-text, rather than the conversational gpt-realtime model. This implementation explicitly labels the actual model and uses the Realtime transcription WebSocket: `wss://api.openai.com/v1/realtime?intent=transcription`. Native URLSession sends authenticated requests; no WebView/frontend gets the key. Session type is transcription, audio is 24 kHz mono PCM16, and turn detection is null as required by this model. Client RMS silence detection or Finish speaking commits the turn. There is no assistant response generation, Jev classification, translation, or spoken audio output in this mode.

A 12-second capture limit, 10-second handshake/final timeout, bounded audio/event/message buffers, one sequential upload worker, ephemeral URLSession, duplicate-event filtering, and item-based partial/final replacement bound each session. Cancellation closes the socket and mic, ignores late events, and coordinates with the existing private-note/microphone admission gate. Permission requests retain the microphone lease until the request returns. Disconnects fail closed; Retry creates a fresh session without replaying prior audio. Incoming provider error payloads and credentials are never logged or displayed.

## Credential setup and live test

The user-provided variable is **OPENAI_ROTA_KEY** in `~/.env` or the process environment. The app reuses the existing serialized literal dotenv reader; it never sources a shell file, copies the key into settings, imports it into Keychain, embeds it in the build, or syncs it. Only an explicitly started OpenAI voice session reads the key. This installation workflow does not read or verify the user's real key; parser tests use dummy strings. No new persistent credential store or permission grant was created.

No live provider/microphone test was performed. Before a live test, authorize use of OPENAI_ROTA_KEY from ~/.env for one bounded session and microphone capture; normal macOS permission prompts must be handled by the user. [Current model pricing](https://developers.openai.com/api/docs/models/gpt-live-transcribe) is $0.017 per minute of audio: a 12-second test is approximately **$0.0034**. A suggested one-test budget is **$0.01**; this is an estimate, not an account-enforced spending cap. Actual service cost so far: **$0**.

## Catalog and execution

- Existing indexed native and installed Chrome/Safari app bundles: 117 on the test Mac.
- Open Rotagivan settings; System Settings is discoverable as its installed app. This does not navigate arbitrary System Settings panels or change their values. No undocumented deep links were added.
- 99 reusable default Mac actions from the existing allowlist (shortcuts, window/media/HUD controls); user-configured actions/macros remain available when enabled. 17 Chrome and 23 Slack shortcuts are available only in the matching active app. All registered non-app actions require confirmation and are revalidated against their captured registry and current app before dispatch.
- Up to 200 enabled, pressable items from the captured app’s standard menu bar, discovered through public AX APIs only when Accessibility is already granted. Discovery does not click/open menus or prompt for permission. Execution resolves the menu path again and validates titles, availability, active PID and AXPress support. Every menu action requires confirmation.

Menu discovery is bounded to one second plus an in-flight AX call (0.15-second messaging timeout), depth five and 200 results. Querying uses an immutable cached action snapshot, normalized Rust index, and cached lookup tables. No disk scan or subprocess per transcript fragment. The actual query benchmark over 417 entries (including 200 synthetic menu entries) on the M4 Pro: median **0.042 ms**, p95 **0.057 ms**, maximum **2.306 ms** across 1,000 mixed queries including initial indexing. This excludes rendering, network STT and actual execution latency.

## Validation and limits

Mock assertions cover configuration, literal key-variable parsing with dummy values, partial/final ordering and duplication, sanitized errors, PCM append without replay, commit, mic denial, private-note cancellation, pending permission cancellation, handshake timeout, disconnect/manual retry, missing-key setup failure, local action routing and unavailable menus. Native mocked HUD tests cover immediate key focus, incremental Rust results, no speech execution, explicit injected app launch, cancellation/stale deltas, two-Return confirmation, held-Return rejection, stale action rejection and one injected execution. Test screenshots were inspected. Original native typing/search checks were rerun and passed after the expanded-catalog integration.

Run `./Rotagivan/test-realtime.sh` for mock checks; append `--ui` for the disposable native HUD (requires a logged-in macOS UI session). `./Rotagivan/test-typing.sh` covers typing. `./Rotagivan/build.sh` produces the signed app with the existing development identity. Full repository regressions remain available through `./Rotagivan/test.sh`; this update does not claim that entire long suite was rerun.

Limits: real OpenAI account/model access, live acoustic accuracy/latency, device interruptions, and live AX menu execution were not validated. Menus that macOS/apps do not expose remain absent; arbitrary right-side menu-bar status icons are not indexed. There are no direct panel edits, automatic sensitive actions, permissions grants, or translation. App launch remains deliberate; sensitive/registered/menu actions use action-time confirmation, with any further system dialog left to the user. Multistage IME composition remains outside the typing feature.

## Installed release verification — October 13, 2026

Rotagivan **1.1.199 (201)** was built and installed/reopened at
`/Applications/Rotagivan.app` using `./launch.sh --keep-accessibility`.
The running executable is `/Applications/Rotagivan.app/Contents/MacOS/Rotagivan`.
The app and embedded Rust dylib pass strict verification against the existing
D47A development certificate; no signing identity, trust, or TCC permissions changed.
Built/installed executable SHA-256:
`51dfe0db4088f76a497f0b07fb2a4bb0ccac9f7e3965a11bde88b91d372b1371`.
Built/installed Rust dylib SHA-256:
`d91e42e4b125682e9952bda97d3ff05c4c083e3aa6d1ca07faf0b9560de35e66`.

Focused Realtime mock/native HUD tests, Rust/Swift typed-search tests,
TemporaryIntentionTests, VoiceMicrophoneAdmissionTests, and ReleaseSettingsTests
passed. Settings verification asserts the visible `voice-provider` selector;
both the settings page and Realtime HUD screenshots were reviewed.
No real API key was read, microphone captured, paid request sent, or real action
executed during verification. The entire long regression suite was not rerun.
The pending sync-settings redesign is excluded from this release.

A signed rollback copy of 1.1.195 (197) was retained locally at
`/private/tmp/rotagivan-pre-gptlive.gLsBEB/Rotagivan.app`.
