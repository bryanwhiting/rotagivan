# Rotagivan

An editable, independent macOS driver and settings app for the ZSA Navigator Trackpad. It connects directly to the Voyager's precision-touchpad HID interface, so it does not depend on the official Navigator app. This is an initial implementation, not yet verified for full behavioral parity with ZSA Navigator.

Features:

- Smooth log-normal cursor response with Fine/Fast sensitivity, transition center/width, live feedback, and release envelopes
- Two-finger horizontal and vertical smooth scrolling
- Adjustable kinetic scrolling
- Configurable one/two-finger tap and double-tap actions, with per-profile overrides
- Tap-hold dragging and drag re-grip
- Normal and Precision profiles
- Configurable profile hotkeys with hold or press-to-switch behavior
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

Copy `Rotagivan.app` from `Rotagivan/build/` into `/Applications`, quit the official Navigator app, then launch the clone. macOS will ask for Accessibility access so the clone can post pointer and scroll events.

Do not run both apps together: each would receive and respond to the same touch reports.

## Configuration and defaults

General → Configuration provides **Copy YAML**, **Save YAML…**, and **Import YAML…**.
For import, paste the YAML text (or open a file), click **Validate**, then confirm
**Replace configuration**. Invalid input does not change preferences. **Undo last
import** restores the previous complete configuration, including shortcuts; that
backup survives restarts. Restoring defaults uses the same backup mechanism.

The versioned file includes all profiles, names, selected default, cursor curves,
scrolling, tap/drag settings, recorded key bindings, activation/click/drag hotkeys,
slider baselines, enabled state, and launch-at-login preference. Accessibility and
Input Monitoring grants, signing credentials, debug data, and transient active
hotkeys are intentionally excluded. Login-item changes remain subject to macOS
approval; global shortcut conflicts with other apps still depend on that Mac.

Values are engine units, **not slider percentages**. The schema begins with
`formatVersion: 1`, `settings:`, and `shortcuts:`. Profile-keyed collections retain
the app's Codable representation: alternating profile IDs and values in a YAML
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

- `Models.swift`: saved profiles and tuning defaults.
- `CursorResponse.swift`: shared log-normal CDF, scan timing, and release-envelope math.
- `MotionCurveEditor.swift`: native parameter controls, live graph, and release editing.
- `GestureEngine.swift`: contact-to-cursor/scroll/tap/drag behavior.
- `EventPoster.swift`: macOS pointer and scroll events.
- `HIDManager.swift` and `TrackpadReport.swift`: device connection and report decoding.
- `HotKeyManager.swift`: configurable profile and mouse-action hotkeys.
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

- **Fine / Fast speed**: low/high sensitivity (internal gain 0–3.36). Fine cannot exceed Fast. Equal values disable acceleration; both at zero disable cursor movement.
- **Transition center**: the halfway speed, logarithmically scaled from 100 to 4,000 device units/second. Higher keeps fine control longer.
- **Transition width**: log-space sigma, 0.35–1.25. Higher makes the transition broader and less steep around the center. A nonzero minimum prevents a near-step response.
- **Smoothing**: temporal filtering of speed and sensitivity, separate from the shape of the curve.

The dashed line marks the center and the shaded band spans the 10th–90th
percentiles (clipped to the graph). The plot has a fixed 0–8,000 input-speed
range so parameter changes remain visible; the response continues beyond its
right edge without a hard cutoff. The vertical display uses a square-root scale
to give low sensitivities more room. Fast is an asymptote, not the graph endpoint.

The live dot shows measured input and applied sensitivity for the active profile.
Live samples are buffered separately from settings. Only the marker and readout
refresh, at 20 Hz; the response curve and profile controls do not rebuild for
each input event. Switch **Live** off to pause the display without changing
cursor behavior.
Smoothing adjusts time-based filtering of both velocity and applied sensitivity.
Sensitivity changes are eased in relative
terms and rate-limited through steep bends, with a quicker return to fine
control. Smoothing 0 bypasses both filters. The live dot shows applied gain, so
it can temporarily sit off the steady-state curve during a transition.
Falloff after lift opens an audio-style envelope: choose Fine or Fast, drag the
end for duration and the middle for decay shape. A zero tail stops immediately;
the maximum tail is 450 ms. Tap/keyboard/physical drags do not coast after lift.
Balanced, Precision, and Wide sweep presets are optional; Undo preset restores
the preceding curve. Existing node profiles retain their endpoint gains, smoothing,
and falloff parameters; the old halfway speed is estimated by interpolation and
the transition is replaced with a broad sigma of 0.75. Pre-node profiles derive
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
