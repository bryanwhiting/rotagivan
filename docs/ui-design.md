# Settings UI design

This note covers how the settings window is laid out and which shared components it uses. The components live in `Rotagivan/UIComponents.swift`.

## Navigation

- There is one sidebar, with one row per section: Devices, HUD, Actions, Voice mode, Pointer & scrolling, General, Sync & backup. Legacy section names such as "Hotkeys" or "Profiles" still redirect in `ContentView.init`.
- **The user controls whether the sidebar is collapsed.** A sidebar button at the far left of the header switches between the full sidebar (icon and label, 196 pt) and an icon rail (56 pt). The choice persists in `@AppStorage("settings.sidebarCollapsed")`. The shortcut is ⌃⌘S. The HUD page no longer collapses the sidebar automatically. Icon-rail rows show the section name as a tooltip.
- Each section has a shortcut, ⌘1 to ⌘7, in sidebar order. Rows keep `settings-section-<name>` identifiers and the selected trait.
- The header shows where you are: the "ROTAGIVAN" overline and the current section title. Ordinary pages no longer repeat that title in large type. Each page starts with its one-line description, which keeps the `settings-page-heading` identifier, so top-alignment checks still apply.

## Header

The header has three parts, always in the same place:

`[sidebar toggle] [ROTAGIVAN / Section title] ············ [profile switcher]`

All other actions belong to the page they affect. The footer shows the version and that changes save automatically.

## Profile management

The old header had a profile picker, a "Rename…" button and an "Add Profile" button, and there was no way to delete a profile. These are now one `RotaProfileSwitcher`:

- A badge with the profile's initial, plus a menu button named after the active profile (`profile-switcher`).
- The menu lists the profiles, with a checkmark on the active one, then a divider and three commands:
  - **Rename…** (`rename-profile`) opens the existing `ProfileNameEditor` sheet.
  - **Duplicate** (`duplicate-profile`) copies the active profile, including every layer and HUD. This uses the existing `addConfiguration`; the limit is still 20 profiles.
  - **Delete…** (`delete-profile`) asks for confirmation, then calls the new `SettingsStore.deleteConfiguration`. You cannot delete the last profile. Deleting the active profile switches to its neighbour first. Input is stopped and restarted around the switch, the same way profile switching already works.

## Components

| Component | Replaces | Notes |
|---|---|---|
| `RotaTokens` | ad-hoc numbers and colours | Spacing (2–22), radii (5/7/12), control heights by `controlSize`, and the light/dark teal accent. |
| `RotaControlChrome` | per-view rounded rectangles | The bezel shared by fields, selects and menu buttons, with hover, pressed and active states. |
| `RotaButtonStyle` (`.rotaPrimary/.rotaSecondary/.rotaDestructive/.rotaGhost/.rotaIcon/.rotaLink`) | `.bordered`, `.borderedProminent`, `.borderless`, `.link` | Settings windows default to secondary. `role: .destructive` turns red. Default-action buttons are primary. |
| `RotaSelect` | every single-choice `Picker` (menu style) | A custom trigger that opens a custom popover list. Arrow keys move the highlight, Return or Space chooses, Escape closes, and typing a letter jumps to a match. Supports sections and icons. To VoiceOver it is a button whose value is the current choice, and it can be adjusted directly. |
| `RotaMenuButton` (`.toolbar/.field/.icon`) | `Menu { } label:` command menus | The trigger is custom-drawn; the menu body stays a native NSMenu (see below). |
| `RotaSegmented` | `.pickerStyle(.segmented)` | A sliding thumb. Each segment is a button with the selected trait. Respects Reduce Motion. |
| `.rotaSwitch`, `.rotaCheckbox`, `.rotaChip` toggle styles | `.switch`, `.checkbox`, `.button` | Each uses `accessibilityRepresentation` with a native `Toggle`, so assistive tech and tests see a normal on/off control. |
| `RotaStepper` | `Stepper` | Compact − and + buttons that can also be adjusted through accessibility. |
| `RotaCard`, `RotaSectionHeader` | `GroupBox`, hand-made pointer cards | A titled card with an optional icon, subtitle and accessory. |
| `RotaDisclosure`, `RotaDisclosureSection` | `DisclosureGroup` | An animated chevron, plus an expanded/collapsed accessibility value. |

### Why command menus keep a native menu body

`RotaMenuButton` draws its own trigger and uses `Menu` with `.borderlessButton` for the menu itself. The command menus, such as tile actions, "Add HUD" and "Window management › Resize window › …", nest three levels deep. A native `NSMenu` gives them submenus, type-ahead, keyboard navigation and VoiceOver without any extra work. It also keeps the `NSPopUpButton`/`NSMenu` structure that the action-menu smoke tests inspect. Single-choice dropdowns are fully custom, using `RotaSelect`.

### Controls left native on purpose

- Pickers and toggles placed inside a `RotaMenuButton` menu become ordinary menu items with checkmarks. Restyling them would break the menu.
- The `List` outline rows in Activity (per-app domains) use the List's own disclosure.
- The calendar in Activity's day popover is the system graphical `DatePicker`. Its trigger is a custom button.
- `NSOpenPanel` and `NSSavePanel` file pickers, system alerts and confirmation dialogs.
- HUD tile chrome (`ExplorerTileChrome` and the starburst sectors) is drawn by the HUD itself. It only got minor polish: shared keycap and hotkey chips, and a capsule "ACTIVE" badge.
