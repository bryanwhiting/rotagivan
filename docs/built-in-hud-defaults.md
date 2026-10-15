# Built-in HUD defaults

HUD → Setup → Built-in layers opens a visual preview. Actions is an editable
default: click a tile to choose its action, clear it, or drag it to another slot.
Restore original resets only the default; existing placed copies are preserved.
New Actions groups and Editing Actions templates copy the saved default.
Media Controls uses the same editable default and restore flow for play/pause,
track navigation, volume and mute. New media groups and templates copy that
default, including intentionally empty layouts. Setup and Add HUD include every
built-in layer.

Recent Apps and Google Chrome Tabs have generated contents. Their default editor
shows illustrative tile positions and lets you set the number of slots, rather
than persisting a particular running app or browser tab. Window Manager retains
its shared visual editor and can restore its original shared layout.

Google Chrome Tabs is available in Setup, Add HUD, and the nested built-in layer
picker. It uses a local, per-open snapshot of Chrome's live tabs. Selecting a tile
focuses the existing tab; it does not create a duplicate. Previous/Next controls
show additional pages. Chrome must be running, with macOS Automation access
granted to Rotagivan. Empty or unavailable snapshots show guidance. If a tab moved
or closed, activation fails safely and asks the user to reopen the HUD.

Only the default layout and assigned layer settings are saved/synced. Live tab
titles and URLs remain transient on this Mac. Settings previews never query or
activate Chrome. Regression tests inject synthetic tab snapshots.
