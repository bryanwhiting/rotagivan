# Local activity

Open **Activity today** from the Rotagivan menu-bar panel. Tracking starts off;
enable **Screen Time** in the Activity window to opt in on this Mac. The UI says
“Opt in to Screen Time settings to see computer usage insights.” This is Rota's
own local setting, not a request to read Apple's Screen Time database. It counts
only the frontmost regular application, not every visible window or background
process. No historical Apple Screen Time database is imported.

The report shows daily active-app totals, app switches, and optional Chrome domains
nested under Chrome. Calendar day boundaries follow this Mac's time zone, including
daylight-saving changes. Domain totals are a subset of Chrome time, not extra time.
Choose another date to inspect retained history.

## Inactivity and browser privacy

App activation notifications update accounting immediately; a five-second timer
samples idle time and optional browser domains. After 15 minutes without input,
the idle stretch is removed back to the last input. Short quiet reading periods
still count. Sleep, lock, inactive sessions, missing samples, and clock jumps do
not create catch-up time. These are estimates, not billing-grade measurements.

Website tracking is off by default. Enable it and explicitly choose **Allow Chrome
access…**; only that button may request macOS Automation permission. Chrome must
already be open. Polling does not request permissions or launch the browser.
Only the front public tab's HTTP(S) domain is retained. Incognito URLs are not
requested. Page titles, credentials, full URLs, paths, query strings, page content,
screenshots, and keystrokes are not stored. Incognito and other browsers count
only toward app time. Website changes are approximate at the sampling boundary.

## Rota action and hotkey statistics

The same Screen Time opt-in gates command statistics. The **Actions** report shows
daily invocation counts and last-used times; **Include unused** adds configured
actions with zero uses on the selected day. The **Hotkeys** report counts physical
triggers registered and handled by Rota, separately from action invocations. It
does not observe arbitrary typing or discover shortcuts used in other apps.
Action counts are dispatch attempts, not proof that the destination app completed
the command. Nested synchronous dispatch helpers do not inflate macro counts.
Website actions retain only their domain as the display name, never the URL.
Opaque action identifiers are hashes, not serialized settings or macro contents.
The app does not store speech transcripts or copy action statistics into sync.

## Storage and deletion

History lives only at
`~/Library/Application Support/Rotagivan/Activity/usage.sqlite`. Local opt-in and
personalization preferences use the separate `local.rotagivan.activity` defaults
domain. Neither is part of profiles, settings YAML, settings export, cloud sync,
API-key storage, or voice-provider prompts. Different Macs build different histories.

The database uses directory permissions 0700 and file permissions 0600 and is
excluded from backups. It is **not application-level encrypted**; FileVault provides
disk encryption when enabled. An administrator or another process running as the
same user may access it. No claim is made that exclusion prevents all third-party
backup tools from copying it. History remains until **Delete all activity…** is
confirmed. Deletion clears app, domain, action, and hotkey history and local prediction state; settings and
bookmarks are untouched. Storage failures pause tracking rather than replacing
unreadable history.

## Local search personalization

**Personalize local search using app history** is independently selectable and off
by default, but only operates while Screen Time opt-in is enabled. Opting out
stops both collection and history-based ranking immediately; retained history can
still be viewed or deleted.
It uses the last 30 days of app duration and adjacent app-switch counts, weighted
with a seven-day half-life. A smoothed conditional next-app probability is combined
with global app frequency. Immutable snapshots keep database work off the typing
path. Only small groups of already-matched, equally text-relevant app results are
reranked. Exact-name matches retain priority. It does not change remote voice-model
prompts or transmit activity data. Turning it off restores the normal search order;
deleting activity clears its learned state.

Run `bash Rotagivan/test-usage.sh` for isolated synthetic accounting/database tests.
