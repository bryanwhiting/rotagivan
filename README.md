# Rotagivan

An editable, independent macOS driver and settings app for the ZSA Navigator Trackpad. It connects directly to the Voyager's precision-touchpad HID interface, so it does not depend on the official Navigator app. This is an initial implementation, not yet verified for full behavioral parity with ZSA Navigator.

Features:

- Cursor speed and acceleration
- Two-finger horizontal and vertical smooth scrolling
- Adjustable kinetic scrolling
- Configurable tap actions: one finger defaults to Option+F19; two fingers defaults to Enter
- Tap-hold dragging and drag re-grip
- Normal and Precision profiles
- Configurable profile hotkeys with hold or press-to-switch behavior
- Configurable single-click, double-click and hold-to-drag keyboard shortcuts
- Launch at login and menu-bar controls
- Imports the official app's current settings on first launch

## Build

```sh
chmod +x Rotagivan/build.sh
Rotagivan/build.sh
```

Copy `Rotagivan.app` from `Rotagivan/build/` into `/Applications`, quit the official Navigator app, then launch the clone. macOS will ask for Accessibility access so the clone can post pointer and scroll events.

Do not run both apps together: each would receive and respond to the same touch reports.

## Current verification and setup

The application builds locally and detects the connected Voyager. An initial “device not open” setup error was corrected by explicitly opening the HID device; successful live operation still needs verification. Enable Rotagivan in System Settings → Privacy & Security → Accessibility and, if requested, Input Monitoring. Quit ZSA Navigator, launch Rotagivan, and use General → Reconnect.

Bundle identifier and preferences domain: `local.rotagivan`. Existing preferences are migrated from `local.navigator.clone`. Builds currently use ad-hoc signing, so rebuilding may require removing and re-adding the installed app in Accessibility.

Live cursor feel, scrolling, hotkey release, dragging, and multi-monitor behavior still require hardware testing after permission is granted. ZSA's exact acceleration/smoothing algorithms and automatic updater have not been reproduced. This version matches the connected Voyager product ID; other ZSA keyboards need additional verified device IDs.

To return to the original, quit Rotagivan and launch `/Applications/Navigator.app`. The clone never writes the original app's settings.

## Hacking guide

- `Models.swift`: saved profiles and tuning defaults.
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
xcrun swiftc Rotagivan/Models.swift Rotagivan/EventPoster.swift Rotagivan/Tests/ClickTests.swift -o Rotagivan/build/click-tests
Rotagivan/build/click-tests
```

## Local development and uninstalling

The coding checkout is `~/gh/bryanwhiting/rotagivan`. Build artifacts, old app backups, and local preferences are not committed. Quit the app before deleting `/Applications/Rotagivan.app`; deleting the installed app does not delete this source checkout or its saved preferences. Rebuild and copy the app back into Applications to reinstall.

No public redistribution license has been selected. This is a private development project, with AI-generated code and protocol references documented above.
