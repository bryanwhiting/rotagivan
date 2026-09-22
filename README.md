# Rotagivan

An editable, independent macOS driver and settings app for the ZSA Navigator Trackpad. It connects directly to the Voyager's precision-touchpad HID interface, so it does not depend on the official Navigator app. This is an initial implementation, not yet verified for full behavioral parity with ZSA Navigator.

## HUD appearance

### Macros and direct HUD layers

The **Macros** page replaces Hotkeys. A macro is a named sequence of 1–32
keystroke or **Open app** steps, with a configurable 0–2000 ms delay between
steps. Add, record, reorder, or remove steps in its editor. For example:
**Open app → Cmd+L → Cmd+V → Return**. Choose **Add open app…**, select an
application, then use ↑ to place it before the keystrokes.

Open app activates an existing instance or launches a closed app, waits for
launch completion and stable foreground focus, and makes that app the target
of the following keys. The step delay gives slow interfaces additional time;
it is not an application-specific readiness check. Opening times out after
10 seconds, and focus confirmation after 2 seconds. Failure or unexpected
foreground changes stop playback instead of sending keys to the wrong app.
All keyboard sequences share a serial, asynchronous playback lane; waits do
not block the UI or trackpad input. App steps store portable bundle IDs, not
executable paths, shell commands, or URL handlers.
Choose **••• → Macros** in a tap/swipe action or a HUD tile's
**Macros & keystrokes** editor. Macro references follow subsequent edits;
existing plain-shortcut assignments retain their original keystrokes. Removing
a referenced macro makes that action inactive, with a warning in the organizer.
The legacy `hotkeyDictionary` YAML field is retained for import compatibility;
entries without `steps` or `sequence` are one-step macros, and existing
keystroke-only `steps` are preserved. Mixed macros use typed `sequence` steps.
Settings and sync include the full sequence and its stable ID.

**HUD** is directly below **Devices**. Add/edit a top-level HUD layer to assign
an **Open this HUD layer from anywhere** keyboard shortcut, or use the visible
**HUD layer** menu beside any tap/swipe action (including single and two-finger
double taps). HUD tiles also offer **••• → Open HUD layer** in their shortcut
editor. No keyboard shortcut is required for gesture activation. Direct launch
stays on that layer until the HUD is dismissed. The
existing in-HUD hold/toggle key remains separate. Launch keys require a modifier
for letters and participate in shortcut conflict reporting.

Use **Choose app…** in the layer editor to restrict a HUD layer to that app.
Its launcher only registers while that app is frontmost, and direct gesture
targets and in-HUD activation keys respect the same restriction. In **App
overrides**, assign a gesture to that layer for app-specific workflows. Nested
tile-group layers can also be app-restricted; direct launch targets are the
top-level HUD layers. Missing or unavailable targets safely do nothing.

New HUD layers start with eight empty slots and no assigned keys or app
restriction; they do not copy the current layer or generate window presets.
Click a tile in the settings preview to open an app/URL picker anchored to
that tile. **Other actions** includes macros, reserved groups, window commands,
and move/copy controls. Group tiles offer their group editor. There is no
separate inspector below the preview. Dragging still moves or swaps tiles.

### Themes

Choose **HUD → Classic / Starburst / Starburst Air**, or use the palette menu
while editing the HUD directly. Classic retains its native material appearance;
Starburst keeps the violet radial panel. **Starburst Air** is the new default:
floating charcoal sectors and thin mint-white perimeter arcs over a rounded,
frosted-glass backdrop. Native macOS material, a fine reflective rim, and a soft
shadow separate the HUD from busy desktops without a heavy panel. The settings
preview uses the same glass. Nested breadcrumb rings and sector hit targets
remain stable. Reduce Transparency replaces the glass with an opaque surface.

Vector HUD and Ember are retired. Saved/imported selections of either migrate
to Starburst Air; Classic and Starburst selections are preserved. Layouts,
actions, and pointer tuning are unchanged. Animations remain brief transitions
only, respecting Reduce Motion and the animation toggle; no continuous drawing
loop was added.

**Starburst** is a violet radial HUD with eight pointed sectors. The outer
choices retain their swipe directions while each group you enter leaves a
concentric inner ring. Its highlighted segment records the direction taken at
that level; the title/breadcrumb identifies the group and the center displays
the current level number. Center tap goes back one level (or closes at the
root). Nested groups, Recent-app groups, Window Manager, and Media Controls use
the same design. It supports the full four-group depth plus a controls level.
Short ring reveals respect Animate HUD feedback and Reduce Motion; no input
timers, looping effects, or new gesture thresholds are introduced. Your existing
theme remains selected until you choose Starburst.

Appearance is shared across Explorer groups, hold layers, window controls, and
media controls, and is included in YAML/cloud configuration syncing. It does not
change any apps, bindings, gesture timing, or window layouts. **Animate HUD
feedback** can be disabled independently; macOS Reduce Motion always wins.
Selection feedback lasts 120 ms and the entrance settles in 160 ms. There are no
looping effects, animation timers, or per-report telemetry: actions execute
immediately, without waiting for animations.

## Profiles, layers, and devices

Settings now start with **Layer actions**, not pointer tuning. The top-right
profile picker selects a complete setup; **Add Profile** copies it, including
all layers, hotkeys, gesture timing, Navigator tuning, per-app overrides, and
App Explorer groups, favorites, themes, hold layers and window layouts. Edit
the name in the header. Existing installations become one **Default** profile,
without changing saved motion or gesture values. Up to 20 profiles are supported.

- **Layer actions:** aligned layer columns with their activation shortcuts and
  tap/swipe bindings. Sharing is on by default. Turn off **Share tap and swipe
  actions across devices**, select Apple trackpad, and enable **Customize Apple
  actions** on any layer. Uncustomized layers follow shared actions; re-enabling
  sharing preserves custom bindings so they can be used again later.
- **App Explorer:** all layouts, groups and Explorer hold layers belong to the
  selected profile. **App overrides** also belong to that profile and apply on
  top of the chosen device's layer actions.
- **Devices:** choose Navigator, Apple actions, both, or neither for the profile.
  Apple input still requires the machine-local opt-in and permissions. This
  selection never disables macOS's own trackpad pointer or scrolling.
- **Pointer & scrolling:** one Navigator response per top-level profile, shared
  by every action layer. Changing an action layer or its default does not change
  cursor speed, scrolling, smoothing, or coasting. Use **Add Profile** for a
  different mouse setup. Existing configurations use their default layer's
  tuning until edited; old per-layer tuning remains in saved data for compatibility.
  Dragging actions now live under **Layer actions**. Apple motion remains native.
- **General:** complete YAML export/import and sync include all profiles and
  their shortcuts, including inactive profiles. Legacy single-configuration YAML
  imports as one Default profile. Account, permission grants, input opt-in,
  startup registration and the master enable switch remain machine-wide.

Switching profiles releases drags, closes HUDs, cancels pending gestures and
returns to that profile's default layer before reconnecting selected drivers.
The menu-bar panel also includes a profile picker. Device support currently
covers Navigator and Apple's built-in/Magic Trackpads; selecting a profile does
not add a driver for unsupported hardware.

## Apple trackpad actions (experimental)

In **Devices**, enable **Allow Apple input on this Mac** and **Use Apple trackpad actions**
to use a built-in Mac trackpad or Magic Trackpad alongside—or instead of—Navigator.
This switch is **off by default**, saved only on this Mac, and not included in
cloud/YAML configuration syncing. Your existing layers and bindings are unchanged.
If an older experimental build stored a `macTrackpad` configuration, that data is
archived in local preferences as `input.legacyAppleTrackpadSettings` before model
migration. It is not reinterpreted or silently enabled as a new gesture binding.

- Uses the active layer's tap, double/triple-tap, and tap/swipe bindings, including
  app-specific overrides. Enable **tap actions** in the layer for tap bindings.
  Native three/four-finger contacts and uncertain/palm contacts are ignored and
  drained until all fingers lift; they are not treated as two-finger taps.
- Keyboard actions, **App Explorer**, and **Window Manager** work through the same
  action pipeline. Once a HUD opens, swipe and lift to select; nested groups,
  Explorer hold layers, tiling sizes, and media controls remain available.
- macOS still owns Apple pointer acceleration, scrolling/momentum, clicks, and
  dragging. Rotagivan does **not** post extra mouse events for Apple touches,
  change System Settings, or seize the device.
  Navigator motion/scroll sliders and synthetic click/drag bindings do not apply
  to the Apple trackpad. Click bindings remain macOS's responsibility, including
  its own “Tap to click” preference.
- While an Apple-controlled **App Explorer or Window Manager** is open, a temporary
  motion-only event filter saves, hides, and pins the actual cursor position so
  swipes select HUD actions without moving it. Closing the HUD restores the saved
  position before showing the cursor. Entering inline editing, disconnecting,
  disabling Apple actions, or stopping Rotagivan releases the filter. Done in the
  editor resumes HUD selection. A keyboard-opened HUD also pauses movement when
  an Apple trackpad is connected, until a different input source takes ownership.
  macOS has a shared pointer, so other mice also pause during this interval;
  clicks, scrolling, and keys are not filtered. Navigator-owned HUDs are unchanged.
  This requires Accessibility permission. If capture fails the HUD closes with a
  status message; if macOS disables the filter, movement resumes and the HUD closes.
  Hide/show calls are paired once per session, including failures and teardown.
  Pinning uses [Apple's event-free cursor warp and balanced hide/show APIs](https://developer.apple.com/library/archive/documentation/GraphicsImaging/Conceptual/QuartzDisplayServicesConceptual/Articles/MouseCursor.html).
  It does not steal app focus or change pointer association.
- **App Explorer → Put mouse in center of selected app** is off by default and
  saved per configuration profile (including YAML export and sync). When enabled,
  an app selection first restores the cursor, then centers it in the successfully
  activated app's focused window after its geometry settles. This works for
  Navigator and Apple app selections, including nested groups and Recents.
  URL/shortcut/media/tiling selections do not invoke it. No focused window,
  failed launch, another HUD, changing focus, or moving the mouse yourself cancels
  centering. Partially off-screen windows use the visible portion if their center
  is outside the displays. Geometry checks use bounded retries and short
  Accessibility timeouts; there is no unbounded wait.
- Native gestures can happen **alongside** a Rotagivan binding. Choose bindings
  that do not conflict with macOS/app gestures, or change those gestures yourself
  in System Settings. Native mouse-down events cancel pending Apple gestures; a short
  80 ms arbitration window before touch-triggered HUDs lets secondary clicks
  arrive even after the raw finger-lift frame. Both physical clicks and macOS
  secondary tap-to-click take priority over opening a HUD. Custom actions do not
  replace native clicking. Mouse buttons are observed globally, so a simultaneous
  click on another mouse also conservatively cancels an Apple gesture.
- Calibration uses the trackpad selected in General and ignores the other device.
  Explorer similarly locks to the triggering/first trackpad. Concurrent touches
  from different devices cannot combine into a gesture.
- Outside a HUD or calibration, Navigator takes priority over a resting Apple
  finger. The interrupted Apple contact is ignored until lift. Apple touches do
  not reset Navigator's cursor falloff or kinetic scrolling, and no speed,
  acceleration, or saved layer values are changed by this arbitration.

This feature dynamically loads Apple's **private, undocumented MultitouchSupport
framework**, because the public event APIs do not supply system-wide raw contacts
for these gestures. It is not an App Store-compatible API contract and may stop
working after a macOS update. Missing framework symbols or unsupported hardware
report a status message rather than disabling the Navigator driver. Device
recognition and contact layout are necessarily reverse-engineered; a future ABI
change cannot be guaranteed safe merely by checking symbol names. Magic Mouse
and Touch Bar are excluded. Use **General → Reconnect** after granting permissions
or if a device stops producing actions. Disabling Apple actions leaves native
trackpad behavior intact.

The adapter's contact layout is informed by the reverse-engineered
[MultitouchSupport header](https://github.com/machinarii/hypervibe/blob/main/MultitouchSupport.h)
and [TrackMagic's earlier header](https://github.com/calftrail/TrackMagic/blob/master/MultitouchSupport.h).
Its millimeter vector is converted to the same logical distance scale as
Navigator (2,048 units per 55 mm). Raw-frame fixtures, gesture output isolation,
device arbitration, and simulated HUD integration run in `Rotagivan/test.sh`.
The separate native HUD smoke harness is
`Rotagivan/Tests/ExplorerCalibrationUISmoke.swift`.
Hardware enumeration was checked on a Mac mini with a Magic Mouse; physical
Apple-trackpad recognition and distance calibration still need verification on
a built-in or Magic Trackpad.

## Quick local build and install

```sh
cd ~/gh/bryanwhiting/rotagivan

# One-time only, unless the signing identity is missing:
zsh Rotagivan/setup-signing.sh

# Build the app:
zsh Rotagivan/build.sh

# Optional regression checks:
zsh Rotagivan/test.sh

# Install and launch:
./launch.sh
```

`launch.sh` quits Rotagivan gracefully, waits for it to exit, copies the signed
build into `/Applications` with `ditto`, verifies its signature, resets only
Rotagivan's Accessibility permission, and reopens the installed copy. It works
from any directory, preserves your app settings, and does
not rebuild or re-sign the app. Use `./launch.sh --check` for a read-only check.
If a copy will not quit, it stops instead of overwriting a running app.

The reset now runs by default. To keep a working Accessibility permission:

```sh
./launch.sh --keep-accessibility
```

Without `--keep-accessibility`, the launcher installs and verifies the build,
runs `tccutil reset Accessibility
local.rotagivan` while Rotagivan is closed, then opens the app and Accessibility
settings. Manually enable `/Applications/Rotagivan.app` (add it with **+** if
needed), then reconnect or relaunch Rotagivan. Close and reopen System Settings
if its list appears stale. This resets the permission decision; it does not
guarantee every old app entry disappears from the list.

The reset is **on by default**, affects only this user's Rotagivan Accessibility
permission, and leaves Input Monitoring, other apps, layers, YAML, and login
credentials untouched. Run it as your normal logged-in user, not with `sudo`.
It cannot grant access automatically or override a managed Mac's policy. A
reset also cannot fix an unstable signing identity: keep using the same local
signing certificate for future builds on that Mac. To validate without making
changes, use `./launch.sh --check`. The previous `--reset-accessibility` flag is
still accepted. After granting access, reopen the app from Applications or use
`--keep-accessibility`; a plain `./launch.sh` will revoke that grant again.

Built app path:

```sh
Rotagivan/build/Rotagivan.app
```

Do not run ZSA Navigator and Rotagivan at the same time; both apps would receive and respond to the same touch reports. On first launch, macOS may require Accessibility and possibly Input Monitoring permission for `/Applications/Rotagivan.app`. If macOS blocks the local build because it is not notarized, right-click the app in Finder and choose **Open** once.

Features:

- Smooth log-normal cursor response with Fine/Fast sensitivity, transition center/width, live feedback, and release envelopes
- Two-finger horizontal and vertical smooth scrolling
- Adjustable kinetic scrolling
- Configurable one/two-finger tap and double-tap actions, including a double-left-click action, with per-layer overrides
- Optional one-finger double-tap-then-swipe shortcuts in eight directions
- Tap-hold dragging and drag re-grip
- Normal and Precision layers
- Configurable layer hotkeys with hold or press-to-switch behavior
- Configurable single-click, double-click and hold-to-drag keyboard shortcuts
- Launch at login and menu-bar controls
- Bundled tuned defaults and complete YAML configuration import/export

## Build

The build uses Swift Package Manager to fetch the pinned Yams 6.1.0 dependency
on the first build. Yams/libyaml are statically linked; the installed app needs
no external YAML tools or network connection. Their MIT notices are included
in the app resources.

```sh
# One-time setup, only after approving a local code-signing certificate:
zsh Rotagivan/setup-signing.sh
chmod +x Rotagivan/build.sh
Rotagivan/build.sh
```

Run `./launch.sh` after building to install and open Rotagivan. Quit the official
Navigator app separately before using Rotagivan. On first installation, macOS
will ask for Accessibility access so Rotagivan can post pointer and scroll events.

Do not run both apps together: each would receive and respond to the same touch reports.

## Configuration and defaults

### Local YAML and account sync

**General → Account & Sync** adds email/password registration and login. The app
saves a complete configuration to `~/.config/rotagivan/settings.yaml` first, then
syncs it to a per-user Cloudflare D1 record when signed in. Changes are debounced
for 500 ms; external YAML edits are checked about every two seconds, and cloud
updates/retries about every 30 seconds. **Sync now** checks immediately.

On another Mac, install Rotagivan and sign in to the same account. Its cloud
configuration is loaded on first login, with a local backup before replacement.
Concurrent offline edits produce a choice: keep this Mac's settings or the cloud
copy. Neither version is silently discarded. Account switching never silently
uploads the previous account's settings to a different existing account.

Local YAML works without an account or internet connection. Invalid YAML pauses
sync and leaves the working app settings intact. **Reload YAML** imports a fixed
file; **Save app settings** backs up and replaces a conflicting local file.
`settings-backup-*.yaml` files in the same directory retain replaced copies;
`sync-state.json` stores per-account revision metadata, not credentials. Keep or
remove old backups as desired. Config files are owner-only (0600), in a private
directory (0700). Symlink config files/directories are rejected.

Passwords never go in YAML or preferences; D1 stores salted scrypt hashes and
Keychain stores the device's login token. Permissions, launch-at-login and this
Mac's enable switch are not changed by sync. Config file IO/YAML decoding and
network requests do not run in the trackpad report path.

Email verification and password-reset email are not available yet: email is the
login name, not verified mailbox ownership. Save your password in a password
manager. **Change password** revokes other devices' sessions. Cloud settings are
access-controlled but not end-to-end encrypted. See [backend setup and security
notes](SyncBackend/README.md) for deployment and API details.

### Keep the cursor still while tapping

**Tapping → Keep cursor still while tapping** is on by default. Initial finger
wobble inside **Tap movement radius** is ignored while the touch can still be
a tap. The action fires at the stationary cursor on lift with no extra click
delay, and recognized taps do not start cursor glide. Ignored movement is never
replayed as a jump. Move beyond the radius or hold past **Tap impact speed** to
begin normal tracking; protection does not re-engage during that touch.

A larger radius steadies taps but delays the start of small intentional motion.
Lower the radius (shown in millimeters) for quicker fine-motion pickup, or turn
this option off for immediate cursor tracking. Existing speed/acceleration and
saved radius/duration values are unchanged. Physical-button and keyboard drags
bypass protection. A second-touch tap-drag starts on the existing 120 ms hold
or movement beyond the protected tap radius; tiny second-tap wobble no longer
starts an accidental drag. Lift still drops immediately. The setting inherits
with tap settings, participates in Copy from, and is included in YAML exports.

### Triple clicks and triple taps

Choose **Triple left click** from the **…** action menu beside any tap to emit
three native left-click down/up pairs at the cursor, with click counts 1, 2,
and 3. The target app decides how to handle a triple click. This is a mouse
action, not a keyboard shortcut.

**One-finger triple tap** and **Two-finger triple tap** can each trigger that
action, another click action, or a recorded shortcut. They default to Nothing,
so existing layers keep their timing. When assigned, three taps of the same
finger count replace the shorter actions. Each tap must satisfy the tap
duration/radius, and successive releases must fit the existing **Double-tap
delay**. A double tap waits that extra interval for a third tap; if none arrives,
it performs its double action (or two singles when no double action is set).

With double-tap-then-swipe enabled, a short stationary third touch triggers the
triple-tap action; a third-touch swipe triggers its directional shortcut instead.
Tap-and-hold dragging remains a second-touch gesture. Triple-tap bindings inherit
from Default and participate in section copying and YAML import/export.

### Double left click from one tap

In **Tapping**, open the **…** menu beside a tap action and choose **Double left
click**. One recognized tap then emits two left clicks with native double-click
counts; this is a mouse action, not a recorded keyboard chord. It is available
for one-finger and two-finger taps as well as their double-tap actions. The
separate double-tap recognition delay still applies if you have assigned a
double-tap action or enabled double-tap-then-swipe. Tap-and-hold dragging remains
available only when the one-finger tap action is **Left click**.

### Scroll response curve

Each layer's **Scrolling** section now has a compact response graph and three
0–100 controls: **Slow speed**, **Fast speed**, and **Transition point**. The
curve blends smoothly between the two sensitivities as finger speed increases.
Raise the transition to retain the slow response longer; drag the dashed line
to position it directly. Equal endpoints give constant sensitivity. Endpoint
controls have finer resolution near zero; changing one never moves the other
(Slow cannot exceed Fast). Both endpoints at zero disable scroll movement.

The graph plots the actual gain function, using a fixed square-root vertical
scale so small sensitivities remain visible. It has no live marker or HID-driven
UI updates. The transition's blend width and brief velocity smoothing are fixed
to keep the editor simple. Both new curves and legacy acceleration use hardware
scan timing (capture uptime when unavailable), not main-thread processing time,
so UI scheduling delays do not cause accidental acceleration changes.

Existing layers retain their original scrolling until a curve control is
edited. Opening settings alone does not migrate or rewrite anything. Initial
endpoints are derived from the previous speed/acceleration; the restore arrow
returns to that previous behavior. **After-scroll coasting** and its coefficient
remain separate and unchanged. **Copy from**, YAML export/import, and account
sync include the curve. The menu bar's **Scrolling** disclosure exposes the same
three controls instead of an unrelated legacy speed slider.

### Per-app tap and swipe overrides

Open **Apps** in settings. **Add app…** selects an installed `.app` by its
bundle identifier (not a window title). Choose **Override an action** to customize
one/two-finger single, double, or triple taps; any direction of tap-then-swipe or
double-tap-then-swipe; or plain two-finger left/right swipes. Record a shortcut,
choose App Explorer, or explicitly choose Nothing. Remove a row with the undo
arrow to inherit that action again; disable or remove the app to inherit all.

Rules apply only while that app is frontmost, on top of whichever layer is
active. They do not change cursor/scroll tuning, tap timing, or saved layer
actions. Tap-based overrides respect the layer's Enable tap actions setting.
App changes cancel pending taps and in-progress gestures to avoid carrying an
action into a different app. Rules are included in YAML and per-account sync.

Chrome is prefilled with **two fingers right → Back (⌘[)** and **two fingers
left → Forward (⌘])**, matching [Chrome's Mac shortcuts](https://support.google.com/chrome/answer/157179).
Delete the preset to opt out; an explicitly empty app-override list stays empty.
Legacy settings without this new field use the preset without rewriting any
existing layer values. Other apps initially inherit everything.

Two-finger navigation is a quick horizontal flick (at least 80 sensor units,
about 2.1 mm on Navigator, completed within 350 ms); the action fires once both
fingers lift. A slow start (over 180 ms), vertical movement, or an unassigned
direction commits to regular scrolling. A reserved horizontal gesture is held
briefly to distinguish it from scrolling; small/ambiguous swipes do nothing.
After committing to scrolling, the same touch cannot turn into navigation.
Both fingers must move together; sensor jumps and uncertain contacts cancel.

### HUD

**HUD** is the single settings page for App Explorer, window management and
appearance. **Reserved Groups** contains three always-available built-ins:
**Window Manager**, **Recent Apps**, and **Actions**. Click one in the HUD page
to configure the shared window layouts or preview the other built-ins. Assign
one to any empty/terminal tile through **••• → Reserved Groups**.

**Actions** starts with Copy (⌘C), Paste (⌘V), Cut (⌘X), Select All (⌘A),
Undo (⌘Z), Redo (⇧⌘Z), Find (⌘F), and Save (⌘S). Adding it creates an ordinary
editable group: rearrange, rename, or customize that instance without changing
the reserved defaults. These are normal keyboard shortcuts sent to the app
active before the HUD opened; support depends on that app. Assigned groups and
shortcuts export/sync using the existing schema. Browsing the built-in library
does not change existing settings or clipboard contents.

**Tile actions:** the **•••** picker uses native macOS menus in both Settings
and the HUD editor. Actions are organized into:

- **Macros & keystrokes:** assign a macro, individual shortcut, or HUD-layer target.
- **App launches:** choose an app, open a URL, or show the chosen app's windows.
- **Reserved Groups:** Window Manager, Recent Apps, and Actions.
- **Create tile group…:** add a named group with its own tiles and layers.
- **Window management:** resize (including Fill
  desktop); toggle/exit full screen; show app windows; minimize; or close.
- **Media controls:** open the volume and playback controls.

These menu choices configure the tile; the action runs when selected in the HUD.
Existing groups keep their edit/rename controls instead of offering replacements
that could discard their contents. Remove a group explicitly to change its type.

**Move or reuse whole groups:** open a tile's **••• → Move or copy…**, choose
the destination layer/group, then a slot. **Move / swap** moves into an empty
slot or swaps occupied tiles; **Copy** requires an empty slot and keeps the
original. Nested groups, capacities, and tile-specific layers are preserved.
The picker includes Explorer-wide and group-local layers, including from the
HUD's inline editor. Recent-app grids are automatic, not storage destinations.
Window Manager groups have their own editable tiles and layers; move or copy
between them from the Window Manager group editor. Transfers cannot target their own descendants or
exceed the existing nesting/size limits. If settings change while the picker
is open, reopen it; no stale edit will overwrite newer settings.

**4 / 8 / 12 / 16 slots:** choose the capacity above the favorites grid. Each
group and each alternate layer has its own capacity. Eight-slot layouts retain
their existing positions; other capacities use evenly spaced radial sectors in
every HUD theme. The settings grid lists those sectors clockwise from the top.
Resizing moves assigned tiles to the closest free sectors without dropping
their contents. Remove tiles first if you want fewer slots than are assigned.
Changing a default page's capacity does not change its alternate layers.
Recent-app groups use their configured capacity as well.

**Group layers:** use **••• → Tile layers…** on a group and add another layer,
then select that layer to edit its slots and capacity. Its recorded key can be
**Hold** or **Tap to toggle**. Toggle state lasts only for this HUD session;
leaving the group cancels its local layer. Physical tap/swipe bindings remain
eight-directional—the expanded radial geometry is Explorer-only.

**Window Manager groups:** use **HUD → Reserved Groups → Window Manager** for the
shared group, or a tile's **••• → Edit Window Manager group…** for its own setup.
Each slot is editable: **Window management → Resize window** assigns a target direction and size
(halves/quarters, thirds, two thirds, or fourths); **Window management** offers
Fill desktop, full-screen toggles, minimize, close, and app windows. A swipe's
direction is independent of the assigned window position. Apps, URLs, shortcuts,
and nested groups also work. Drag to swap, move/copy groups, choose 4/8/12/16 slots,
and use local hold/toggle layers just as in App Explorer. **Edit** in the HUD
opens the same editor and returns to the originally captured window afterward.
Existing presets keep their placements until edited; explicitly empty groups
stay empty. Full-screen windows still offer only **Exit full screen**.

**Fill desktop** resizes the target within the desktop's usable bounds;
**Toggle full screen** changes macOS full-screen mode. These are different
operations, matching Apple's distinction between [desktop tiling](https://support.apple.com/en-ph/guide/mac-help/mchlef287e5d/mac)
and a [full-screen Space](https://developer.apple.com/library/archive/documentation/General/Conceptual/MOSXAppProgrammingGuide/FullScreenApp/FullScreenApp.html).
When the target is full screen, Window Manager shows only **Exit full screen**.
Other tiling and window commands are blocked; Escape still closes the HUD.
Reopen Window Manager after exiting full screen to tile the window.

**App windows and window commands:** an app tile's **••• → App launches → Show this app’s
windows** option opens that running app's window list instead of activating its
default window. Or assign **Window management → Show app windows** to inspect the
app that was active when Explorer opened. Window lists include minimized
windows and paginate in sets of 16 (Previous/Next buttons or left/right arrow
keys). Selecting restores and raises that specific window. Window titles and
handles are temporary and are never saved or synced. Apps must expose their
windows through macOS Accessibility; there is no screenshot or screen-recording
requirement.

Assignable **Window management** actions also include Fill desktop, Toggle full screen,
Exit full screen, Minimize window and Close window. Close uses the app's normal
close button, preserving any save confirmation; it does not force-quit the app.
Window Manager's settings can bind these commands to local hotkeys too. Apps
may refuse resizing or full-screen changes; the HUD reports those failures.

**Tile-specific layers:** open a group's **••• → Tile layers…**, enable
**Use tile-specific layers**, then **Add layer**. For Window Manager, use
**••• → Edit Window Manager group… → Add layer**. Each tile
owns its keys: for example, hold **Y** for thirds inside one Window Manager and
hold **Y** for two thirds inside another. Group layers replace only that group's
apps, URLs, shortcuts and nested groups. Window Manager layers replace its tiles
the same way. Assign each tile's size through **••• → Window management → Resize window**. Select
a layer and use **Edit…** to change its name, activation behavior or key.

These keys take effect after entering their tile, not on the Explorer root.
Release the key to return to that tile's default; going back out cancels its
held layer. Keys are matched against the nearest tile-specific set, so keys
from enclosing sets do not unexpectedly activate alongside it. An enabled,
empty set explicitly disables inherited keys. Otherwise existing tiles inherit
their enclosing Explorer layers for backward compatibility. Turning custom
layers off asks before removing them. Tile layers follow their tile when moved
or swapped and are included in YAML export and sync. Up to 16 layers per scope,
128 layers overall, four group levels and 256 total slots are supported.

**Explorer hold layers:** use **Add layer** above the favorites grid in General
settings or the inline editor. Name the layer, record a key (new layers
suggest **Y**), and choose hold or tap-to-toggle activation.
New layers copy the currently edited slots; choose the layer in
the **Explorer-wide layer** picker to replace its apps, URLs, shortcuts, and groups.
**Edit…** changes its name/key/activation; **Remove** asks before deleting it.

While the HUD is open, hold the layer key to temporarily switch its contents.
Release it to restore the prior Explorer page. In Window Manager, layer keys
switch to that layer's assigned tiles, including any window sizes. Edge placements
use the chosen fraction in one dimension; corner placements use it in both.
The most recently pressed layer wins if multiple keys are held. Changing layers
mid-swipe drains the current touch; lift, then make a fresh swipe. Escape closes
the HUD. Release layer keys before using **Edit**. These keys are Explorer-local,
not global shortcuts and not the cursor/tap layers. Use a key that isn't already
intercepted by another global shortcut. Layer definitions and slots export/sync;
the held state does not. Existing Explorer-wide layers are preserved.

**Media Controls:** choose **Media Controls** from a slot's **•••** menu, then
select it in Explorer. Swipe **up/down** for volume up/down, **top-right** for
play/pause, **top-left** for mute/unmute, and **left/right** for previous/next
track. Lift to apply; the HUD stays open for repeated adjustments. Center tap
returns to the parent Explorer; Escape closes. These send standard macOS media
keys to the system's active media app/output; some external audio devices do not
support software volume adjustment. No music-service login is needed.

Click **Edit** in the Explorer HUD, or press **E** while it is open, to customize
favorites right there. The inline editor starts in the current group and offers
the same app picker, URL editor, named groups, rename, and removal controls.
Changes save immediately. **Done** returns to the explorer; you do not need to
open General settings. In Recent mode, Edit customizes your fixed Favorites.

In **Edit**, drag an app's icon or name onto another direction to swap their
positions. Drop onto an empty slot to move it. URLs and whole groups move the
same way, including inside nested groups; dropping onto a group swaps its slot,
not its contents. Targets highlight while dragging, and dropping outside a slot
or onto the center cancels. The **••• → Move or swap with** menu offers the same
operation without dragging. Changes save and sync automatically. Recent-app
contents remain automatically ordered, but their group tile can be moved.

While editing, the HUD stays open without its navigation timeout. Trackpad taps
temporarily become normal clicks and gesture shortcuts pause, without changing
your saved layers. Native file pickers and naming sheets keep the editor open.
Releasing the hotkey that opened the HUD does not cancel editing. Finish or close
the editor to restore your gesture bindings; switching to another app closes it.

Choose **App Explorer** from a tap action's **…** menu, or from a direction's
action menu under **Single tap, then quick swipe** / **Double-tap, then swipe**.
For example, assign **Swipe Down → App Explorer** under double-tap-then-swipe.
No keyboard shortcut is required. Existing gesture bindings are not overwritten.

In **HUD**, the root always opens **Favorites**. The settings preview uses the same
renderer as the actual HUD: its selected theme, 4/8/12/16 positions, icons,
shortcut names and nested Starburst rings. Select a tile in the preview to edit
it below, or drag between tiles to move/swap. Preview clicks never launch apps,
send keys or move windows. Theme and appearance options are above the preview;
the compact inline editor retains its tile controls.
Each empty/app/URL slot menu offers **App launches → Choose app…**,
**App launches → Open URL…** (or **Edit URL…**),
and **Create tile group…**. Create a group, give it a name, and fill its own
slots. **Edit group** opens its layout; breadcrumbs and the center **Back**
button return to its parent. **Rename…** preserves all contents. Removing a
group asks for confirmation and removes its descendants too. Groups may contain
more groups (up to four levels and 256 total entries); names, contents, and
positions export and sync along with the rest of the configuration.
Choose **Reserved Groups → Recent Apps** in a slot menu to add an automatically filled
group, or open an existing group's editor and set **Group contents → Recent apps**.
You can rename it, nest it inside other groups, and tap the HUD center to go back.
Its slots are ranked **left, top-left, top, top-right, right, bottom-right, bottom,
bottom-left**, from most to least recently used. It shows up to eight other running
apps, excluding the current app and Rotagivan. The editor previews the rank in
each direction. Switching an existing group to Recent apps preserves its assigned
favorites; switch back to **Assigned favorites** to restore them. The group type
syncs, but recent-app history stays local to each Mac.
Choose **Reserved Groups → Window Manager** from a slot's **•••** menu (in HUD settings or the
inline Explorer editor) to add a tiling destination, including inside groups.
Select it, then make a fresh swipe and lift to tile the window in the app you
were using: **left/right** place it in that half, **diagonals** in that quarter,
**up/down** place it in the top/bottom half. All eight directions are positional;
none enters macOS full screen or maximizes. Center tap returns to the parent
Explorer; Escape cancels. Tiling uses the window's current display and excludes
the Dock/menu bar. Accessibility must be enabled. Full-screen windows and windows
that do not support resizing show a message; some apps enforce a minimum size.
The destination saves and syncs; window references and geometry are never synced.

To open tiling directly, go to **Layers → Tapping**, open the **…** action menu
for a single, double, or triple tap, and choose **Window Manager**. Both one- and
two-finger taps support it. Enable custom tap settings for a non-default layer
if it currently inherits from the default. No Explorer favorite or keyboard
shortcut is required. When opened directly, center tap closes the tiling HUD.
The binding follows the active layer, supports tap overrides for specific apps,
and exports/syncs with your configuration. Existing bindings are not changed.

Choose **Macros & keystrokes → Assign macro or keystroke…** from a slot's **•••** menu to assign a keyboard shortcut
instead of an app or URL. Record the chord or use **••• → Set shortcut manually…**
if another app intercepts it. Give it an optional name (for example, “Go back”).
Swipe to the slot and lift: Explorer closes, then sends the shortcut using the
same keyboard-event path as tap actions. A changed foreground app or layer cancels
the pending dispatch. Shortcut slots work inside groups, support drag/swap and
**Edit shortcut…**, and export/sync with your settings. Recent-app groups remain
automatically populated rather than accepting fixed shortcut slots.

Web favorites load their site's favicon (with a globe fallback) and support an optional custom name; swipe and lift to
open the URL in your default browser. Only full `http://` and `https://` links
without embedded usernames/passwords are accepted. URLs export and sync with
your settings, so avoid links containing secrets or private sign-in tokens.
Favorites keep their exact slots, including empty or unavailable slots, and can
launch apps that are not running. Bundle IDs, positions, mode, and the optional
hold shortcut export and sync; absolute application paths are not included.

**App launches → Choose app…** fuzzy-searches `/Applications`, `~/Applications` (including
nested Chrome app folders), and `/System/Applications` off the main thread.
Type a partial name or abbreviation such as `gchr`, select an app, and press
Return. Results include app icons and folder locations. Paste a full `https://`
or `http://` URL to add a website instead, with an optional display name.
**Browse…** still lets you choose apps elsewhere. Selected app paths are remembered
locally for launching Chrome apps that Launch Services has not indexed; those
path hints are not exported or synced. Only the app bundle ID and name sync.

Recent apps remain available through **Reserved Groups → Recent Apps** on any
tile. The old **Default mode** and **Hold for recent apps** controls are removed.
Legacy values remain readable in old YAML for lossless compatibility, but the
root mode always resolves to Favorites and the old global shortcut is no longer
registered or treated as a reserved key. HUD layer keys still work normally.

Finish the opening gesture and lift. A frosted HUD shows your favorites, or up
to eight other running apps in Recent mode. Recents start at the left and continue
clockwise. Make a **fresh swipe** toward an app, then **lift to
switch**. The cursor stays still; highlighted app positions do not reorder while
the HUD is open. You can also click a tile. Selecting a group keeps the HUD open
and shows its eight slots. A fresh short tap without swiping, or a click on the
center, goes back one level; at the root it closes the HUD. Group navigation
never launches an app or clicks into the app behind it. Each new opening starts
at the root. Swipe out and back to the center and lift, press Escape, or click
close to cancel completely. It also closes after 15 seconds of navigation inactivity, on app
switch/Space change, layer or tap-setting changes, sleep, or device disconnect.

Recency is learned from [macOS application activation notifications](https://developer.apple.com/documentation/appkit/nsworkspace/didactivateapplicationnotification)
while Rotagivan runs. Only bundle IDs are stored locally; this history is not
included in exported YAML or cloud sync. On first use, unknown running apps fill
remaining slots in launch-date order until their actual usage is observed.
The current app, Rotagivan, and background-only helpers are excluded. If fewer
than eight eligible apps are running, remaining tiles stay empty. Gesture
assignments themselves do inherit, copy, export, and sync with layers.

### Two-finger tap and swipe combinations

Under a layer's **Tapping** section, enable **Two-finger tap, then quick swipe**
or **Two-finger double-tap, then swipe**. Tap with both fingers, lift both, then
swipe with both fingers together. The double-tap variant requires two completed
two-finger taps before the swipe. Assign a recorded shortcut or App Explorer to
any of eight directions, including diagonals. Both gestures are off by default.

Each variant has its own swipe window, distance, and bindings; the single-tap
variant also has a quick-swipe duration. Actions fire once both fingers lift.
Slightly staggered landings/lifts are accepted. A reserved swipe cannot move the
cursor, scroll, or start dragging. Long holds cancel; lift both fingers before
starting ordinary scrolling again. Without a preceding tap, normal two-finger
scrolling and app-specific navigation continue to work.

Stationary follow-up taps still use the existing two-finger double/triple-tap
actions. If no swipe follows, the earlier tap action runs after its recognition
window. These settings support layer inheritance, Tapping **Copy from**,
per-app overrides, YAML export/import, and account sync. They do not alter the
one-finger gesture settings.

### Single tap, then quick swipe

In a layer's **Tapping** section, enable **Single tap, then quick swipe** and
record a shortcut for any of the eight directions. Perform two contacts:
**tap → lift → quick swipe → lift**. The second contact can start somewhere
else on the trackpad. Its movement does not move the cursor; the shortcut fires
once on lift. Unassigned or ambiguous directions do nothing.

**Swipe window** is the gap allowed after the first tap (default 200 ms).
**Quick-swipe duration** is how quickly the second contact must finish
(60–300 ms, default 180 ms). **Swipe distance** sets minimum travel, displayed
in millimeters when available. Holding past the duration hands control to
tap-and-hold drag, if enabled for a left-click tap; otherwise normal pointer
tracking resumes. No mouse-down is posted while deciding. Release ends a drag.
A quick stationary second contact remains a double tap, so double-tap-then-swipe
and triple taps can still be used.

**Calibrate tap + swipe…** captures 10 valid attempts, suppressing pointer and
shortcut output. **Apply** sets this gesture's start gap and duration to their
medians (clamped to the supported ranges); it does not change double-tap timing,
distance, bindings, or enablement. Slow holds over 300 ms are rejected. Increase
the duration manually if the median cutoff misses your slower attempts.

The feature is off until enabled with at least one binding. When configured,
single-click output waits for a possible swipe, and held drags wait for the
quick-swipe duration. Inheritance, Tapping **Copy from**, YAML, and account sync
include these settings. Existing layers and motion tuning are unchanged.

### Double-tap, then swipe

In a layer's **Tapping** section, enable **Double-tap, then swipe** and record
a shortcut for Left, Right, Up, Down, Top left, Top right, Bottom left, or
Bottom right (the menu also supports manual entry).
Perform two completed one-finger taps, then touch again, swipe and lift. This
is three contacts: tap–lift, tap–lift, swipe–lift. The third contact does not
move the cursor or scroll; its keybinding fires once on lift. Unassigned
directions do nothing. The gesture is off by default and has no effect until
enabled with at least one assigned direction. Diagonal bindings start unassigned;
an unassigned diagonal does not fall back to a horizontal or vertical shortcut.

**Swipe window** (100–800 ms, default 350) is the time after the second tap to
begin the swipe. **Swipe distance** (shown in millimeters when connected) is independent
of cursor sensitivity. Finish the swipe within 700 ms; ambiguous direction boundaries,
extra fingers, sensor jumps, layer changes, and explicit dragging cancel it.
When enabled, single taps wait for double-tap recognition and ordinary double
taps wait for the swipe window. Without a swipe, the normal double-tap action
runs (or two single-tap actions if no double action is configured). A short
third touch falls back to the double action. Tap-and-hold on the second contact
retains the existing drag behavior.

Directions use eight 45-degree sectors. A narrow dead zone between adjacent
sectors cancels uncertain swipes rather than choosing the wrong shortcut.
Swipe calibration accepts all eight directions using the same classification.

Secondary layers inherit this gesture from the default layer unless
**Set Custom Tap settings** is checked. The Tapping section's **Copy from**
and whole-configuration YAML both include the new settings.

### Physical distance units

**Swipe distance** and **Tap movement radius** display and accept millimeters
on the trackpad surface, not screen pixels. The scale is read from report 1's
absolute X/Y HID elements when the device connects. Our connected Navigator
reports 0–2048 logical coordinates and a 55 mm span on both axes: a saved swipe
distance of 60 becomes **1.61 mm**, and a tap radius of 30 becomes **0.81 mm**.
The swipe range is approximately 0.54–6.45 mm; the tap radius range is 0–4.30 mm.
These are firmware-reported physical distances, not a ruler-based calibration.

Conversion is display-only until you edit a control. Existing values, YAML
fields, timing, sensitivity, and gesture recognition remain unchanged in raw
coordinates. Millimeter inputs convert back to the same underlying values.
If disconnected, or if physical metadata is missing or incompatible between
axes/contacts, the controls explicitly show **units**, not an invented mm scale.
One-finger tap radius is maximum displacement from the landing point; two-finger
tap detection uses accumulated movement. Neither limits the separation between taps.

Unit interpretation follows the [HID report descriptor convention](https://learn.microsoft.com/en-us/windows-hardware/design/component-guidelines/touchpad-sample-report-descriptors)
and [HID distance units](https://software-dl.ti.com/simplelink/esd/simplelink_msp432e4_sdk/3.30.00.22/docs/usblib/msp432e4/api_guide/html/group__hid__device__class__api.html).

### Tap-to-drag pickup

With one-finger tap set to Left click and tap-and-hold dragging enabled, tap,
lift, then touch and hold or move to drag. The second contact may land anywhere
on the trackpad: it starts a fresh movement origin, so repositioning does not
jump the cursor. Pickup allows at least 400 ms after the first tap's lift (or
your double-tap delay if longer), independently of tap impact speed. Gentle
movement beyond the tap radius starts dragging when stationary-tap protection
is on (otherwise the movement threshold is 4 device units);
holding still for 120 ms also works. A quick second lift remains a double tap,
and a drag ends immediately when you lift. Your saved timing and motion values
are not changed by this behavior.

### Calibrate gesture timing

Open **General → Tap calibration**, select **ZSA Navigator** or **Apple trackpad**,
then choose double tap, triple tap, tap + swipe, or double tap + swipe.
Calibration is shared by every current and future action layer in this top-level
profile, including custom layers. It does not require enabling an action first.
Each device keeps separate timing even when tap actions are shared across devices.
With the trackpad connected, the guide collects 10 valid one-finger attempts.
Wait for the ready prompt between attempts. Invalid attempts do not count.
Cursor movement, clicking, dragging, and gesture shortcuts are suppressed
while collecting samples; press Escape to cancel at any time. Input resumes
after the tenth attempt so you can review and apply the result.

**Calibrate triple tap…** records ten three-tap attempts. It calculates separate
medians for lift 1 → lift 2 and lift 2 → lift 3, then shows their sum as the
combined rhythm. Apply saves each interval independently (50–600 ms, rounded to
milliseconds); both one- and two-finger triple taps use these timings. When a
triple-tap action is configured, its first interval governs the first pair and
its second interval governs the third tap. The ordinary double-tap setting is
not overwritten. Older layers fall back to the existing double-tap interval.

Double-tap timing measures the first lift to the second lift. Swipe calibration
also measures the second lift to the third touchdown; finish that third contact
with a swipe and lift. The median is the average of the two middle values from
10 attempts. **Apply** saves those medians (rounded to milliseconds), bounded
by the supported 50–600 ms double-tap delay and 100–800 ms swipe window. There
is no hidden timing cushion: slower-than-median attempts may need a slightly
larger delay/window afterward. This changes only those timing settings, not
your actions, tap movement radius, swipe distance, or cursor settings. The
shared double-tap delay also applies to two-finger double taps.

Cancel, closing settings, or switching away from the app leaves settings
unchanged and releases capture. Disconnecting, disabling, or changing the
reference layer's tap settings cancels capture. Changing the active layer or
top-level profile also cancels capture so an interrupted test cannot save stale
results. Use **Timing adjustments (milliseconds)** in General for manual edits.
Existing layer timing is preserved until that timing is calibrated or edited
there; before then, the controls display the default layer's values. Shared
calibration overrides timing, not actions, and is included in YAML and sync.

### Macro organizer and shortcut conflicts

Open **Macros** in the settings sidebar:

- **Macros** names ordered keystroke sequences without registering additional
  hotkeys. Choose them from **••• → Macros** in an action editor, including HUD
  tiles. Tiles show the macro name and sequence; editing a referenced macro
  updates its assignments. Legacy plain-key assignments keep their original
  keys. Macros are scoped to the top-level profile and included in YAML exports,
  profile copies, and sync. No sample bindings are preloaded.
- **Conflicts & overrides** audits the selected layer/device, its app-specific
  rules, global activation/click/drag/HUD hotkeys, and nested HUD groups. It
  distinguishes competing registered keys from harmless reuse of an outgoing
  shortcut. App overrides show the global action → app action, including explicit
  “Nothing” rules. Two-finger navigation remains independent of tap-to-click.
  HUD-local overlaps and shortcuts sent to combinations also registered by
  Rotagivan are flagged as potential overlaps, not guaranteed failures.
- **All assignments** is a searchable inventory with app scope, precedence, and
  an option to include inactive actions. Choose another layer/device to audit
  its actions; keys in unrelated HUD groups are not treated as simultaneous
  conflicts.

This is an audit of **Rotagivan's configured bindings**, not a scanner of other
apps' private shortcuts or macOS shortcut settings. Runtime registration errors
are displayed when macOS rejects one of Rotagivan's global hotkeys. Macro steps
are audited as outgoing combinations, not registered keys. Launchers restricted
to different apps do not conflict with one another.

### Sharing settings

General → Configuration provides **Copy YAML**, **Save YAML…**, and **Import YAML…**.
For import, paste the YAML text (or open a file), click **Validate**, then confirm
**Replace configuration**. Invalid input does not change preferences. **Undo last
import** restores the previous complete configuration, including shortcuts; that
backup survives restarts. Restoring defaults uses the same backup mechanism.

The versioned file includes all layers, names, selected default, cursor curves,
scrolling, tap/drag settings, recorded key bindings, activation/click/drag hotkeys,
slider baselines, enabled state, and launch-at-login preference. Accessibility and
Input Monitoring grants, signing credentials, debug data, and transient active
hotkeys are intentionally excluded. Login-item changes remain subject to macOS
approval; global shortcut conflicts with other apps still depend on that Mac.

Values are engine units, **not slider percentages**. The schema begins with
`formatVersion: 1`, `settings:`, and `shortcuts:`. The UI calls these **layers**;
existing YAML keys such as `additionalProfiles` and `profileGestures` stay unchanged
for compatibility. Layer-keyed collections retain
the app's Codable representation: alternating layer IDs and values in a YAML
sequence. Start with an exported file when editing by hand. Imports reject
unknown keys, duplicate keys/IDs, invalid ranges or references, multiple documents,
aliases, and files over 1 MB.

`Rotagivan/DefaultConfiguration.yaml` is the factory configuration captured from
the current tuned app for v1.1.49 (51). Fresh installations use it without applying
legacy slider migrations. Existing saved settings are not overwritten by an
upgrade. **General → Restore defaults…** restores that snapshot. No automatic
renormalization is performed by import or reset.

Run all regression checks with `zsh Rotagivan/test.sh` (isolated test preferences).

## Current verification and setup

The application builds locally and detects the connected Voyager. An initial “device not open” setup error was corrected by explicitly opening the HID device; successful live operation still needs verification. Enable Rotagivan in System Settings → Privacy & Security → Accessibility and, if requested, Input Monitoring. Quit ZSA Navigator, launch Rotagivan, and use General → Reconnect.

Bundle identifier and preferences domain: `local.rotagivan`. Existing preferences are migrated from `local.navigator.clone`. Builds now require a persistent signing identity and pin the designated requirement to its certificate and the bundle identifier. The build fails rather than falling back to ad-hoc signing. Local setup keeps the non-extractable private key in your user Keychain, grants codesign access, and trusts the certificate for code signing only. The public certificate is kept in ignored `Rotagivan/.signing/`. This is local development signing, not Apple notarization or a distribution certificate.

Moving from old ad-hoc builds to this identity requires a one-time removal and re-addition of `/Applications/Rotagivan.app` in Accessibility. Quit the app and System Settings before resetting its grant, then add that exact installed path. Do not launch older copies from build or backup folders. Preserve the Keychain identity across updates; deleting or replacing it requires granting permission again. A new computer needs a new local identity (or an Apple Developer signing setup).

Live cursor feel, scrolling, hotkey release, dragging, and multi-monitor behavior still require hardware testing after permission is granted. ZSA's exact acceleration/smoothing algorithms and automatic updater have not been reproduced. This version matches the connected Voyager product ID; other ZSA keyboards need additional verified device IDs.

To return to the original, quit Rotagivan and launch `/Applications/Navigator.app`. The clone never writes the original app's settings.

## Hacking guide

- `Models.swift`: saved layers and tuning defaults.
- `CursorResponse.swift`: shared log-normal CDF, scan timing, and release-envelope math.
- `MotionCurveEditor.swift`: native parameter controls, live graph, and release editing.
- `GestureEngine.swift`: contact-to-cursor/scroll/tap/drag behavior.
- `EventPoster.swift`: macOS pointer and scroll events.
- `HIDManager.swift` and `TrackpadReport.swift`: device connection and report decoding.
- `HotKeyManager.swift`: configurable layer and mouse-action hotkeys.
- `ContentView.swift`: settings interface.

Protocol references: the connected device's HID descriptor and [ZSA's firmware report format](https://github.com/zsa/qmk_modules/blob/main/navigator_trackpad/navigator_trackpad_ptp.c). Application code is independently written; no ZSA binary or artwork is bundled.

Run decoder checks:

```sh
xcrun swiftc Rotagivan/TrackpadReport.swift Rotagivan/Tests/ReportTests.swift -o Rotagivan/build/report-tests
Rotagivan/build/report-tests
xcrun swiftc Rotagivan/Models.swift Rotagivan/CursorResponse.swift Rotagivan/EventPoster.swift Rotagivan/Tests/ClickTests.swift -o Rotagivan/build/click-tests
Rotagivan/build/click-tests
xcrun swiftc Rotagivan/Models.swift Rotagivan/CursorResponse.swift Rotagivan/Tests/CursorResponseTests.swift -o Rotagivan/build/curve-tests
Rotagivan/build/curve-tests
```

## Cursor response editor

The horizontal axis is finger speed (Fine on the left, Fast on the right). The
vertical axis is sensitivity: screen movement per unit of finger movement.
The curve is a log-normal cumulative distribution, not editable segments:
`gain(v) = fine + (fast - fine) * Phi(log(v / center) / width)`.
At zero speed the gain is Fine; at high speeds it approaches Fast smoothly.
This is a sensitivity cap, not an absolute pixels-per-second speed limit.
All controls display 0–100:

- **Fine / Fast speed**: low/high sensitivity (internal gain 0–3.36). A precision taper dedicates more of the 0–100 control range to low gains, with decimal entry in settings and matching menu-bar controls. Fine cannot exceed Fast. Equal values disable acceleration; both at zero disable cursor movement.
- **Transition center**: the halfway speed, logarithmically scaled from 100 to 4,000 device units/second. Higher keeps fine control longer.
- **Transition width**: log-space sigma, 0.35–1.25. Higher makes the transition broader and less steep around the center. A nonzero minimum prevents a near-step response.
- **Smoothing**: temporal filtering of speed and sensitivity, separate from the shape of the curve.

Fine/Fast control positions use `gain = 3.36 * expm1(4 * position / 100) / expm1(4)`.
This changes the controls' scale, **not** the runtime acceleration curve. Existing
gains are read through the inverse mapping, so their displayed numbers change
while physical behavior is preserved. The former linear value 10 displays at
about 46.25, and 54 displays at about 85.0. Zero and the existing maximum are
unchanged; no slider baselines, layers, presets, or saved gains are reset.
Other controls keep their existing scales.

The dashed line marks the center and the shaded band spans the 10th–90th
percentiles (clipped to the graph). The plot has a fixed 0–8,000 input-speed
range so parameter changes remain visible; the response continues beyond its
right edge without a hard cutoff. The vertical display uses a square-root scale
to give low sensitivities more room. Fast is an asymptote, not the graph endpoint.

The live dot shows one-finger Navigator input and applied sensitivity for the
active layer. It does not plot two-finger scrolling or native Apple pointer motion.
Live samples are buffered separately from settings. Only the marker and readout
refresh, at 20 Hz; the response curve and layer controls do not rebuild for
each input event. Switch **Live** off to pause the display without changing
cursor behavior.
The sampler stays alive across parent view updates and cancels when the overlay
is removed. Input reports publish distance metadata only when it actually changes,
including when switching devices; repeated equal values do not invalidate the UI.
Regression tests exercise 20,000 cursor/scroll reports with zero HID view
notifications and render the Live marker under 125 Hz parent updates, including
off/on, layer changes, and finger lift. Physical smoothness still needs hardware
verification on the installed build.
Smoothing adjusts time-based filtering of both velocity and applied sensitivity.
Sensitivity changes are eased in relative
terms and rate-limited through steep bends, with a quicker return to fine
control. Smoothing 0 bypasses both filters. The live dot shows applied gain, so
it can temporarily sit off the steady-state curve during a transition.
Falloff after lift opens an audio-style envelope: choose Fine or Fast, drag the
end for duration and the middle for decay shape. A zero tail stops immediately;
the maximum tail is 450 ms. Tap/keyboard/physical drags do not coast after lift.
Balanced, Precision, and Wide sweep presets are optional; Undo preset restores
the preceding curve. Existing node layers retain their endpoint gains, smoothing,
and falloff parameters; the old halfway speed is estimated by interpolation and
the transition is replaced with a broad sigma of 0.75. Pre-node layers derive
the endpoints and center from legacy motion settings. New saves contain only
distribution parameters. The shape changes intentionally; it does not reproduce
the old nodes exactly. Scrolling and tapping settings are untouched.

Design references (no external implementation copied):

- [NIST log-normal distribution](https://www.itl.nist.gov/div898/handbook/eda/section3/eda3669.htm): cumulative distribution and median/shape parameters. Its use for cursor response is our design choice, not a NIST recommendation.
- [libinput pointer acceleration](https://wayland.freedesktop.org/libinput/doc/latest/pointer-acceleration.html): velocity-based gain and bounded sensitivity.
- [FabFilter transfer-curve display](https://www.fabfilter.com/help/pro-c/using/displays): input/output graph and live metering.
- [Precision Touchpad report timing](https://learn.microsoft.com/en-us/windows-hardware/design/component-guidelines/touchpad-windows-precision-touchpad-collection): wrapping scan-time timestamps in 100 µs units.
- [Apple pointer design](https://developer.apple.com/videos/play/wwdc2020/10640/): distinguishes velocity-based acceleration from inertia after lift. This is an independent tunable curve, not a reproduction of Apple's private trackpad calibration.

## Local development and uninstalling

The coding checkout is `~/gh/bryanwhiting/rotagivan`. Build artifacts, old app backups, and local preferences are not committed. Quit the app before deleting `/Applications/Rotagivan.app`; deleting the installed app does not delete this source checkout or its saved preferences. Rebuild and copy the app back into Applications to reinstall.

No public redistribution license has been selected. This is a private development project, with AI-generated code and protocol references documented above.
