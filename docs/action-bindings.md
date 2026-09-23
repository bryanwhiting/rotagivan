# Actions, triggers, and scopes

An action describes what to do. A trigger describes the input that invokes it.
`ActionBinding` pairs the two; the containing configuration owns its scope.

## Shared editors

- `BindingTriggerPicker` chooses a keyboard chord, tap rhythm, tap-and-swipe, or plain two-finger horizontal swipe.
- `BindingActionPicker` chooses a keystroke, saved action/macro, application, URL, HUD destination, Mac/window command, media command, or pointer action.
- `BindingEditor` combines those controls and checks same-scope collisions.
- `NamedHotkeyEditor` edits reusable output sequences. Input assignment opens `BindingEditor`; output keystrokes remain physical keyboard events.
- HUD layer bindings are independent of tiles. An empty Default, alternate, nested, or Window Manager layer can own assignments.

Legacy `RecordedShortcut` references can carry a typed `assignedAction`. Such references must go through the common action executor, never through the physical keystroke poster. This also lets legacy tap/swipe storage carry actions beyond its original enum without changing page layout.

## Scope and precedence

| Scope | Owner | Resolution |
| --- | --- | --- |
| Global keyboard input | `StoredSettings.actionBindings` | Visible HUD handles a matching local key first; otherwise the registered global action runs. |
| Profile-wide gesture input | `StoredSettings.actionBindings` | Overrides the layer gesture; an app-specific gesture rule may override it. |
| Trackpad layer/device | `ProfileGestures` | Existing inheritance and device customization apply. |
| App-specific gesture | `AppGestureOverride` | Overrides the effective gesture while that app is frontmost. |
| HUD-local input | The visible HUD container's `actionBindings` | Active only in that container; no accidental inheritance from parent tiles or other layers. |

While the HUD owns trackpad input, its local gesture recognizer handles assigned gestures and replays unassigned navigation strokes to the HUD selector. Global gestures do not also fire. Editing, calibration, and the built-in app-window chooser have their own input modes.

Keyboard hold-to-activate and hold-to-drag controls retain their press/release semantics; a one-shot tap is not silently treated as a hold.

## HUD destinations

`hudActionDestinations()` is a navigation catalog, not a list of editable tile grids. It includes Recent Apps and Window Manager destinations. `tileContainers()` remains the editable transfer catalog, excluding generated Recent Apps grids by default.

`BindingAction.hudPath` stores the structural target within a namespace. `windowOwnerPath == nil` denotes App Explorer, `[]` denotes the standalone Window Manager, and a nonempty owner identifies a Window Manager tile under App Explorer (including alternate-layer ancestry). The relative `hudPath` then selects a layer or group inside that window container. Validation and runtime navigation use the same namespace rules.

## Verification

- `UnifiedBindingScopeTests`: navigation vs transfer, recent/owned/alternate window targets, persistence, missing destinations, and legacy key collisions.
- `ActionBindingRuntimeTests`: empty-layer inputs, tile action dispatch, nested targets, source ownership, calibrated gestures, global routing, cancellation, and app precedence.
- `ConfigurationTests`: typed payload validation and YAML round-trips for every action family and scope.
- `HotkeyOrganizerTests`: trigger-to-action orientation, output conflict analysis, and one visible row per assignment with searchable output details.
- `HUDBindingUISmoke` and `HotkeyOrganizerUISmoke`: native rendering and save paths.

Physical output records remain available to conflict analysis, but the organizer folds them into their owning assignment. Searches and the keyboard map still match those output keys.
