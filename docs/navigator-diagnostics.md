# Navigator diagnostics

The ZSA Navigator can feel smooth on one Mac and glitchy on another with the same settings, because settings sync carries the whole configuration. The difference is the machine: how it delivers HID reports, which other drivers touch the device, how the displays are arranged, and whether the device is still in precision-touchpad mode. This page explains how to capture that difference and what each finding means.

## Running it

1. Open Settings, choose **Devices** in the sidebar, and press **Device diagnostics** in the ZSA Navigator card.
2. While the status reads "Measuring for 3 seconds", keep **one finger moving** on the Navigator. The probe measures the real report rate; a resting finger measures nothing.
3. The report is written to `~/Desktop/Rota-device-diagnostics.txt`. Press **Show in Finder** to reveal it.
4. Run it on **both** Macs and compare the two files side by side (`diff`, or open both in a text editor). Every section below is designed to be compared, not read alone.

The file contains nothing secret: no serial numbers, no keys, no typed text, and no settings beyond pointer tuning. It is safe to paste into an issue.

## Reading the report

### Mac

`chip`, `architecture` and `macOS` identify the machine class. Note `input monitoring` and `accessibility trusted`: both must be granted. A locally built app has its own signing certificate on each Mac, so permissions never carry over.

### Displays

One line per display with its frame, visible frame, scale and refresh rate, and the primary desktop height the cursor code uses to flip AppKit coordinates into Quartz. Compare the arrangement between Macs: negative origins, mixed 1× and 2× scales, and a non-primary main display all change how posted cursor positions are clamped at screen seams.

### Other ZSA software running

Any running app whose bundle identifier contains "zsa" (ZSA Navigator, Keymapp). Rota checks for the ZSA Navigator app only when the driver starts; an app launched later is not detected and can put the device back into mouse mode or drive the cursor itself.

### Navigator driver state

What Rota believes: connected or not, when it last matched and opened the device, the result codes of the open and of the precision-mode request, and the distance scale it read from the report descriptor. `0xe00002e2` on the open result means Input Monitoring was refused.

### HID interfaces for vendor 0x3297

One block per IOKit HID interface the Navigator exposes. The important lines:

- **precision touchpad interface**: the interface Rota matches (usage page 0x0D, usage 0x05). There should be exactly one. More than one means the device enumerates differently on this Mac and the driver may have opened the wrong one.
- **usage pairs**: `0x1:0x2` is a mouse collection, `0xd:0x5` is the touchpad collection, `0xd:0xe` is the configuration collection.
- **advertised report interval**: what the USB descriptor promises, usually 8000 µs (125 Hz). Compare with the measured scan interval below.
- **registry … clients**: kernel drivers attached to the interface. An `AppleUserHIDEventDriver` or `IOHIDEventDriver` client on the touchpad interface means macOS is also interpreting the reports.
- **input mode feature report 4**: `3` is precision-touchpad mode, which Rota sets when it connects. `0` means the device fell back to mouse mode and the cursor you see is macOS's own mouse driver, with macOS acceleration and no tap actions. That is the single most likely cause of "works but feels wrong".
- **probe**: three seconds of raw reports read directly from IOKit on a background thread, so its arrival times are true arrival times. `lengths` should be only `16B`, `report ids` only `id1`, `unparsed` zero.

The probe statistics:

| Line | Healthy | Meaning when not |
|---|---|---|
| arrival interval | mean ≈ median ≈ 8 ms, max < 20 ms | The host received reports irregularly. |
| scan interval | mean ≈ median ≈ 8 ms | The device's own clock: this is the real report rate. A median of 16 ms means the device or the USB path runs at 62.5 Hz. |
| dropped | 0 | Scan-time gaps that are whole multiples of the median: reports the device sent that never reached the process. |
| duplicates | 0 | Identical scan times: the same frame delivered twice. |
| late deliveries | 0 | A report arrived more than 50 ms after the device spacing implied: the receiving thread was busy. |
| coalesced | 0 | Reports arrived less than 0.5 ms apart although the device spaced them: a burst after a stall. |
| largest one-frame finger jump | small | A jump near or over 400 units in one frame used to freeze the cursor for that frame (see below). |

### Active pointer settings

The cursor and scroll curves, tap and drag settings for the active layer. These should be identical on both Macs. If they are not, sync has not completed.

### Last 200 input events

The same report stream as seen by the app on the main thread, plus the statistics above computed over it. The line "navigator frames seen by the app during the probe window" lets you compare the app path with the probe directly: if the probe is clean but the app path shows late deliveries or coalesced bursts, the Mac is starving the main thread, not the device.

The table columns: host uptime, source (`nav` or `apl`), device scan time, scan delta, arrival delta, touching contacts, confident contacts, physical button, contact id, x, y.

## Ranked hypotheses

Ordered by how likely each is to produce "glitchy on one Mac, fine on the other" given the code, with the signature to look for in the report and the fix each implies.

### 1. The main thread delivers reports late, in bursts

Evidence in the code: `Rota/HIDManager.swift` schedules the `IOHIDManager` on the main run loop (`IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), …)`) and the report callback hops to the main queue again (`DispatchQueue.main.async`). The `receivedAt` timestamp is taken when the main loop finally services IOKit, so any UI work, HUD warm-up, favicon fetch, application-index scan or settings redraw delays every report behind it. The kernel input queue is finite; a long enough stall drops reports outright. The cursor then moves in steps instead of continuously, which is exactly what "glitchy" looks like. A slower Mac, more displays, or a heavier set of running apps makes this worse on one machine only.

Signature: probe statistics clean, app-path statistics show `late deliveries` or `coalesced` above zero, or app-path `dropped` higher than the probe's.

Fix: schedule the HID manager on a dedicated thread's run loop. All three IOKit callbacks already forward to the main actor, so the change is confined to `start()`/`stop()`. The gesture engine stays on the main actor; only the timestamping and parsing move off it.

### 2. Precision-touchpad mode was lost and never re-asserted

Evidence in the code: `didMatch` sends the mode feature report once (`IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, 4, [4, 3])`) and nothing ever sends it again. There is no `NSWorkspace.didWakeNotification` observer in `HIDManager.swift` (the Apple trackpad input has one). A dock or hub that power-cycles the port, a sleep/wake where IOKit keeps the same device object, or a later-launched ZSA app resets the device to mouse mode while Rota still shows "connected". macOS's own mouse driver then moves the cursor with its acceleration curve and no tap actions, which feels like a different, worse trackpad.

Signature: `input mode feature report 4: 0 (mouse: PTP mode was lost)`, driver state "connected", probe reports few or no 16-byte frames, and the last-200 table has no recent `nav` rows although the cursor moves.

Fix: re-send the mode report on wake and whenever the device has been silent while the app expects frames; re-check for ZSA apps when they activate, not only at start.

### 3. A slower or irregular report rate trips per-frame thresholds

Evidence in the code: the cursor path judged a one-frame finger jump against a fixed 400-unit distance (`guard magnitude < 400` in `GestureEngine.swift`), which at 125 Hz is a sensible ID-reuse guard but at 62.5 Hz rejects ordinary fast flicks, freezing the cursor for that frame. Report rate depends on the host controller and hub, so this is machine-dependent.

Signature: `scan interval` median near 16 ms or an advertised interval other than 8000 µs; `jumps at or over the 400-unit legacy guard` above zero.

Fix: **done in this change.** The guard is now a speed (`GestureEngine.cursorJumpLimit(interval:)`: 400 units per 8 ms, scaled by the measured interval, capped at 1,200), tested by `Rota/Tests/CursorJumpGuardTests.swift`. The remaining timing code (`CursorTiming`, the velocity and gain filters) already uses the device scan clock and is rate-independent.

### 4. The wrong HID interface was opened

Evidence in the code: the matching dictionary selects usage page 0x0D / usage 0x05 and `didMatch` keeps the first matching device only (`guard … self.device == nil`). A composite device can enumerate its interfaces in a different order on a different USB topology.

Signature: more than one block marked "precision touchpad interface", or the probe on the connected interface showing `unparsed` frames or lengths other than 16.

Fix: prefer the interface whose maximum input report size is 16 and that carries report ID 1 elements; list the rest.

### 5. Another driver is also interpreting the touchpad reports

Evidence in the code: the device is opened shared (`kIOHIDOptionsTypeNone`), not seized, so any kernel event driver attached to the same interface keeps receiving reports. A ZSA app launched after Rota is not detected either.

Signature: an `AppleUserHIDEventDriver`/`IOHIDEventDriver` client on the touchpad interface, or a ZSA app in the running list. The cursor moves twice per finger motion, or taps click twice.

Fix: warn when a ZSA app appears; investigate whether a seized open is acceptable on that macOS version, or confirm the kernel driver ignores PTP reports.

### 6. Display arrangement and the read-back of the cursor position

Evidence in the code: `EventPoster.move` reads the current cursor position from `CGEvent(source: nil).location`, adds the delta and posts an absolute position, clamping to the nearest `NSScreen` frame after flipping with the primary display's height. If the HID system has not yet applied the previous posted event, the next read is stale and that delta is lost, which shows as rubber-banding; and at display seams the clamp snaps to the nearest edge.

Signature: glitches confined to one display or to screen edges; a displays section with mixed scales, negative origins, or a main display that is not the first screen.

Fix: keep an expected position between posts and use relative delta fields, falling back to read-back only when something else moved the pointer.

### 7. Permissions on a per-certificate basis

Each Mac signs its own build, and Input Monitoring grants attach to the certificate. A rebuild or certificate change silently revokes the grant until the next relaunch.

Signature: `input monitoring: denied` or open result `0xe00002e2`.

Fix: re-grant in System Settings › Privacy & Security › Input Monitoring, then Reconnect.

### 8. Display scale changes the apparent speed, not the smoothness

Cursor deltas are in points. A 1× external display shows half the travel per finger movement compared with a 2× Retina panel.

Signature: different `scale` values between Macs with the same cursor settings. Feels slow or fast, not glitchy.

Fix: optional per-display gain scaling; low priority.

## What to send back

The two report files. Most of the questions above are answered by one line each:

- `input mode feature report 4` — is it still 3?
- probe `scan interval` median — 8 ms or 16 ms?
- app-path `late deliveries` and `coalesced` — zero or not?
- number of interfaces marked "precision touchpad interface" — one?
- `clients` on that interface — anything besides `IOHIDInterface`?
