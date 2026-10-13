# Typing launcher (1.1.196 / build 198)

Open App Explorer and type immediately. Ordinary printable keys start a local application search; arrows select, Return launches the selected exact bundle, Backspace edits, and Escape closes. Reopening clears the query. Typing exits automatic voice mode. Unmodified letter bindings in the ordinary Explorer now yield to typing; modified shortcuts and Window Manager behavior remain available. Touch selection is suspended while searching.

The existing background application index supplies native apps, installed Chrome app bundles, and installed Safari web app bundles under `/Applications`, `~/Applications` (including nested Chrome Apps directories), `/System/Applications`, and `/System/Cryptexes/App/System/Applications`. The latter covers modern macOS Safari. Browsing history, passwords, browser databases, and network services are never queried. Browser bookmarks/tabs that have not been installed as apps are outside this search.

Rust is compiled with the existing local rustc into a signed bundled dynamic library. The Swift bridge normalizes Unicode/case/accents once per index rebuild, builds Rust's in-memory name/bundle-ID index during background refresh, and runs exact, prefix, substring, and subsequence matching with stable snapshot-order tie breaks. Queries neither scan disk nor launch subprocesses. File notifications and the existing TTL refresh replace complete snapshots; read errors preserve the last complete index. Launch revalidates bundle identity, rejects missing/replaced bundles, and checks presentation generation to prevent a pending launch after reopening. Duplicate app names remain distinct by full path; paths are displayed in results. Icons use a generic local system glyph to avoid filesystem work per keystroke.

## Validation

- Signed build and deep/strict signature verification passed using the saved development identity; no identity/trust/permission changes.
- Rust: 2 tests passed (ranking, Unicode, duplicates, benchmark).
- Swift/Rust bridge assertions passed, including diacritic folding, fuzzy matching, nonmatches, duplicate paths, and replacement snapshots.
- Existing catalog, application-index, and native filesystem-observation regressions passed. Observation checks require the logged-in session outside a restricted sandbox.
- Native UI test passed immediate key focus, rapid typing, Rust library loading, selection, injected launch, reset on reopen, Unicode deletion, empty-result Enter, Escape, and Window Manager isolation. Launch is injected: no real app is opened by the test. Search screenshot inspected.
- Apple M4 Pro: 1,000 mixed queries over 117 installed apps, median 0.007 ms, p95 0.008 ms, max 0.122 ms (includes first indexing). Rust-only synthetic 2,000-entry/1,000-query benchmark: median 0.115 ms, p95 0.197 ms, max 0.265 ms. These measure matching/bridge time, not full screen rendering or launch latency.

Run focused checks with `./Rotagivan/test-typing.sh`; full regressions remain `./Rotagivan/test.sh`. Build with `./Rotagivan/build.sh`.

## Installed with the Realtime launcher

The typed-search component is included in the installed **1.1.199 (201)** release.
Invoke App Explorer with your existing shortcut/gesture, then type to search.
Focused Rust, bridge, and native typing tests were rerun successfully for this
installation. See [Realtime release verification](openai-realtime-launcher.md#installed-release-verification--october-13-2026)
for signing, installation, rollback and live-provider verification boundaries.

The original development batch included voice/intention changes and corrected
one `dictation:` call-site argument to the control's existing `speech:` parameter.
The release retains the shared microphone-coordination dependencies while
preserving unrelated sync work separately. No paid API calls were made in testing.

Limits: text input is driven by native key events; multi-stage IME composition is not implemented. No installed Safari web apps were present on this machine, so actual Safari web-app activation was not exercised; they use the same app-bundle discovery/launch path. Full physical-keyboard end-to-end activation and full app-launch latency were not benchmarked. The existing 950×850 Explorer panel sizing is retained.
