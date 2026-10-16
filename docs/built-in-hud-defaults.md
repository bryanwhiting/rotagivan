# Built-in HUD defaults

In HUD settings, the **Built-in defaults** section of the HUD list opens a visual preview. Actions is an editable
default: click a tile to choose its action, clear it, or drag it to another slot.
Restore original resets only the default; existing placed copies are preserved.
New Actions groups and Editing Actions templates copy the saved default.
Media Controls uses the same editable default and restore flow for play/pause,
track navigation, volume and mute. New media groups and templates copy that
default, including intentionally empty layouts. The Built-in defaults list and
**New HUD → Built-in** include every built-in layer.

Recent Apps and Google Chrome Tabs have generated contents. Recent Apps shows
illustrative positions. Google Chrome Tabs previews the actual open tabs on this
Mac in both the default editor and selected workspace HUD, with Refresh tabs in
the default editor. Neither editor persists a running
app or browser tab; both let you set the number of slots. Window Manager retains
its shared visual editor and can restore its original shared layout.

Google Chrome Tabs is available in Built-in defaults, New HUD, and the nested
built-in layer picker. It uses a local, per-open snapshot of Chrome's live tabs. Selecting a tile
focuses the existing tab; it does not create a duplicate. Previous/Next controls
show additional pages. Chrome must be running, with macOS Automation access
granted to Rotagivan. Empty or unavailable snapshots show guidance. If a tab moved
or closed, activation fails safely and asks the user to reopen the HUD.
The current Chrome tab appears on the left; other tabs follow clockwise by focus
changes observed while Rotagivan runs. For tabs it has not observed, it uses the
latest page-visit timestamp from this Mac's Chrome History databases, then Chrome's
tab order. A history visit is a navigation, not a tab-focus event, so it cannot
reconstruct exact past switching. History is read locally and read-only; tab URLs,
visit timestamps, and the lightweight focus history are never saved or synced by
Rotagivan. The reader includes live WAL data when available and falls back to a
nonblocking on-disk checkpoint read if Chrome holds the database lock.
The Chrome tab tiles also show profile names from Chrome's local `Local State`
metadata, matched to open URLs through each profile's read-only History. Chrome's
AppleScript tab interface does not report a profile ID, so a name followed by `?`
means the URL appeared in more than one profile and the most recent visit was
used as a best guess. Tabs without a matching history visit have no profile
label. These names are never saved or synced by Rotagivan.

Only the default layout and assigned layer settings are saved/synced. Live tab
titles and URLs remain transient on this Mac. The Chrome settings preview reads
tabs but never activates them. Regression tests inject synthetic tab snapshots.
