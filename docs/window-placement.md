# Window placement: ultrawide and app-size constraints

## Reference and scope

Compared with [Rectangle](https://github.com/rxhanson/Rectangle) at commit
`1d46069c27b3b0564bd7cc1e6d97bf6d53093079`, especially:

- [AccessibilityElement](https://github.com/rxhanson/Rectangle/blob/1d46069c27b3b0564bd7cc1e6d97bf6d53093079/Rectangle/AccessibilityElement.swift): size/position writes are separate; moving can release a transient size restriction at the old display edge.
- [ImmediateWindowPlacement](https://github.com/rxhanson/Rectangle/blob/1d46069c27b3b0564bd7cc1e6d97bf6d53093079/Rectangle/WindowMover/ImmediateWindowPlacement.swift) and [WindowMover](https://github.com/rxhanson/Rectangle/blob/1d46069c27b3b0564bd7cc1e6d97bf6d53093079/Rectangle/WindowMover/WindowMover.swift): align the accepted size to the intended zone and keep it within usable display bounds.
- [ScreenDetection](https://github.com/rxhanson/Rectangle/blob/1d46069c27b3b0564bd7cc1e6d97bf6d53093079/Rectangle/ScreenDetection.swift): choose the window's display by overlap rather than assuming the primary display.

The new geometry and settling engine is an independent implementation of these
ideas. Rectangle code is not vendored. Like Rectangle, placement turns the target
app's `AXEnhancedUserInterface` flag off for the duration of one placement and
restores it afterwards: macOS sets that flag in any app an Accessibility client
talks to, and Chrome and Electron then animate frame changes and report
in-between geometry. Measured on Chrome 1.1.247: a left-half tile with the flag
on ended at the window's old height and origin after the settling passes; with
it off the tile landed exactly in one pass. We do not change VoiceOver settings,
reset permissions, install Rectangle, or add private window APIs. Existing
desktop-transfer code is unchanged.

## Behavior

All geometry remains in global top-left-origin Accessibility **points**. Only
partition boundaries are quantized using the selected display's backing scale;
we do not multiply the desktop's positions by the display's pixel resolution.
Halves, thirds, two-thirds and fourths use common rational boundaries, preserving
remainders instead of leaving one-pixel gaps between complementary tiles.

The display with greatest window overlap wins. If a window is off every display,
the nearest display to its center wins; equal ties use stable input order. Menu
bar and Dock space are excluded using the visible frame intersected with the
display's full frame. No display topology or user Dock settings are rewritten.

Tiling and maximize share one placement pipeline. It reads reported AXMinSize or
AXMinimumSize where available, chooses a move/resize order that avoids temporary
overflow, retries size at the destination and reads back the actual frame. A
transient old-edge limit must not become a permanent smaller size: move using
the larger of the requested and currently accepted size, then retry resizing.

Apps can enforce minimum/maximum sizes or terminal-cell increments. After bounded
settling, an accepted constrained size is anchored to the selected outer edge or
corner; unconstrained axes are centered in the requested zone. Fixed-size windows
are moved without trying to resize them. A limited maximize is centered in the
usable display. Exact fractions are best effort, not a promise to override an app.

An oversized window keeps its top/left edge reachable and reports a limitation.
Position refusals, disappearing windows, invalid geometry and focus changes do
not report exact success. Focus loss stops further writes to the captured window.
Existing full-screen/minimized guards remain; no other window is silently chosen.
Settling uses up to four passes and bounded AX messaging timeouts; each pause
waits until two consecutive frame reads agree (at most ~180 ms) instead of a
fixed delay. A placement the app refuses is reported on the swipe path too.

## Verification

WindowTilingTests covers 32:9/21:9 and portrait areas, negative and above-primary
display origins, odd dimensions, 1×/2× backing scales, complementary fractions,
off-screen display selection, reported/unreported minima, maximum/fixed sizes,
terminal increments, deferred resizing, old-edge release, refused positions,
focus cancellation, invalid/disappearing windows and oversized title-bar reachability.
These are injected window fixtures, not evidence of testing every third-party app
or a physical ultrawide monitor. The user's affected apps remain a live follow-up.
