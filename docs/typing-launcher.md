# Typing launcher (1.1.196 / build 198)

Open App Explorer and type immediately. Ordinary printable keys start a local application search; arrows select, Return launches the selected exact bundle, Backspace edits, and Escape closes. Reopening clears the query. Typing exits automatic voice mode. Unmodified letter bindings in the ordinary Explorer now yield to typing; modified shortcuts and Window Manager behavior remain available. Touch selection is suspended while searching.

The existing background application index supplies native apps, installed Chrome app bundles, and installed Safari web app bundles under `/Applications`, `~/Applications` (including nested Chrome Apps directories), `/System/Applications`, and `/System/Cryptexes/App/System/Applications`. The latter covers modern macOS Safari. Passwords and network services are never queried. Chrome browsing history is read only when the explicit opt-in below is on; otherwise the History file is never opened. Browser bookmarks/tabs that have not been installed as apps are outside this search.

## Chrome history (opt-in)

**General → Launcher → "Search Chrome history in the launcher"** (default off; stored as `settings.searchChromeHistory` and synced with the rest of the configuration, the history itself is never synced). This toggle is the only entry point.

When it is on, `ChromeHistoryIndex` (`Rota/ChromeHistory.swift`, an actor) keeps the 3,000 most recently visited pages across every Chrome profile directory that has a `History` file (`~/Library/Application Support/Google/Chrome/Default`, `Profile N`). Chrome locks that SQLite file while it runs, so each refresh copies it (and its journal or WAL) to a private `0700` temporary directory, opens only that copy (read-write, so SQLite can roll back a journal caught mid-transaction; Chrome's own files are never opened), reads `url, title, last_visit_time, visit_count` from `urls` (hidden and non-http(s) rows excluded, newest first), and deletes the copy. Rows are deduplicated by site prefix (`ChromeBookmarkTabs.sitePrefix`: scheme, host and path, no query or fragment), keeping the newest title and summing visit counts, then bounded to 3,000.

Refresh cadence: every 2 minutes while enabled, plus on launcher open when the cached list is older than 30 s. All file work runs off the main thread; the launcher shows the previous list immediately and swaps in the new one when it lands. Turning the toggle off cancels the periodic read and clears the cache at once.

In the launcher the rows read `History · <page title>` (or the URL when Chrome stored no title) with the host in the detail line and a `clock.arrow.circlepath` icon. They sit after apps, folders, Chrome tabs, website bookmarks and app menus in the catalog, so an exact app or tab name still wins ties. The row id carries the URL, so typing part of a host or path matches too. Return opens the URL through the ordinary bound-action path (`performBoundAction(.openURL(url))`), which reuses an already-open Chrome tab for the same site instead of opening a duplicate.

Performance: the catalog is only rebuilt when a snapshot arrives, and the per-keystroke search runs over the same index as before. `Rota/Tests/ChromeHistoryTests.swift` builds a fixture History database with sqlite3 (locked with `BEGIN EXCLUSIVE` to prove the copy path), checks merging, ordering, the actor's on/off and staleness behaviour, the launcher rows, and times the search over 3,000 history rows (asserting under 3 ms when the Rust index is available; pass the `librota_search.dylib` path as its first argument to use it). `Rota/benchmark.sh` also reports `launcher: search per keystroke (+3000 history)`.

Rust is compiled with the existing local rustc into a signed bundled dynamic library. The Swift bridge normalizes Unicode/case/accents once per index rebuild, builds Rust's in-memory name/bundle-ID index during background refresh, and runs exact, prefix, substring, and subsequence matching with stable snapshot-order tie breaks. Queries neither scan disk nor launch subprocesses. File notifications and the existing TTL refresh replace complete snapshots; read errors preserve the last complete index. Launch revalidates bundle identity, rejects missing/replaced bundles, and checks presentation generation to prevent a pending launch after reopening. Duplicate app names remain distinct by full path; paths are displayed in results. Icons use a generic local system glyph to avoid filesystem work per keystroke.

## Validation

- Signed build and deep/strict signature verification passed using the saved development identity; no identity/trust/permission changes.
- Rust: 2 tests passed (ranking, Unicode, duplicates, benchmark).
- Swift/Rust bridge assertions passed, including diacritic folding, fuzzy matching, nonmatches, duplicate paths, and replacement snapshots.
- Existing catalog, application-index, and native filesystem-observation regressions passed. Observation checks require the logged-in session outside a restricted sandbox.
- Native UI test passed immediate key focus, rapid typing, Rust library loading, selection, injected launch, reset on reopen, Unicode deletion, empty-result Enter, Escape, and Window Manager isolation. Launch is injected: no real app is opened by the test. Search screenshot inspected.
- Apple M4 Pro: 1,000 mixed queries over 117 installed apps, median 0.007 ms, p95 0.008 ms, max 0.122 ms (includes first indexing). Rust-only synthetic 2,000-entry/1,000-query benchmark: median 0.115 ms, p95 0.197 ms, max 0.265 ms. These measure matching/bridge time, not full screen rendering or launch latency.

Run focused checks with `./Rota/test-typing.sh`; full regressions remain `./Rota/test.sh`. Build with `./Rota/build.sh`.

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
