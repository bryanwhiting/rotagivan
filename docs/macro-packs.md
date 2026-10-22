# Macro packs

A macro pack is a YAML file holding a set of macros for one application or
website, written by hand or exported from Rotagivan. Importing a pack adds
its macros to the saved-action library, where they can be assigned to any
hotkey, tap, swipe or HUD tile like any other macro.

Rotagivan ships packs for Slack, Google Chrome and Gmail. See
`Rotagivan/MacroPacks/` for the files and copy one to start your own.

## File format

```yaml
format: rotagivan-macro-pack/1
name: Slack
app: com.tinyspeck.slackmacgap      # OR  website: https://mail.google.com  (one, or neither = global)
appName: Slack                      # optional display name, only with app
notes: Shortcuts follow Slack's macOS defaults.   # optional, shown after import
macros:
  - name: Jump to a conversation
    keys: cmd+k
  - name: Mark all as read
    keys: shift+esc
  - name: Reply in thread, then jump back
    steps: [cmd+shift+t, esc]
    delay: 120            # ms between steps, optional (default 100)
```

| Key | Required | Meaning |
| --- | --- | --- |
| `format` | yes | Exactly `rotagivan-macro-pack/1`. |
| `name` | yes | Pack name, up to 120 characters. Shown as the subgroup under Macros and in the picker. |
| `app` | no | Bundle identifier of the app that receives the keystrokes (contains a dot, at most 255 characters). |
| `appName` | no | Display name for the app. Only valid with `app`. Defaults to the pack name. |
| `website` | no | An `http(s)` URL with a host, at most 512 characters. A pack has `app` or `website`, never both. |
| `notes` | no | Up to 2000 characters, shown in the confirmation after import. |
| `macros` | yes | 1–500 entries. Each has `name` (unique within the pack) and either `keys` (one chord) or `steps` (1–32 chords), plus optional `delay` (0–2000 ms). |

Unknown keys anywhere in the file are rejected, as are YAML anchors and
aliases. Parse errors name the macro and the chord that failed, for
example `Macro 2 “Reply” step 2: unknown key “bogus” in “shift+bogus”`.

## Chord names

A chord is zero or more modifiers followed by one key, joined with `+`
(case does not matter, spaces around `+` are ignored). Symbol forms such as
`⌘⇧K` are also accepted.

| Modifiers | Spellings |
| --- | --- |
| Command | `cmd`, `command`, `⌘` |
| Shift | `shift`, `⇧` |
| Option | `opt`, `option`, `alt`, `⌥` |
| Control | `ctrl`, `control`, `⌃` |

| Keys | Spellings |
| --- | --- |
| Letters and digits | `a`–`z`, `0`–`9` |
| Function keys | `f1`–`f20` |
| Return / Enter | `return`, `enter` (the keypad Enter key) |
| Whitespace and editing | `tab`, `space`, `delete` (`backspace`), `forwarddelete` |
| Escape | `esc`, `escape` |
| Arrows | `left`, `right`, `up`, `down` |
| Navigation | `home`, `end`, `pageup`, `pagedown` |
| Punctuation | `,` `.` `/` `;` `'` `[` `]` `\` `-` `=` `` ` `` (also `comma`, `period`, `slash`, `semicolon`, `quote`, `leftbracket`, `rightbracket`, `backslash`, `minus`, `equals`, `backtick`) |

Key codes are the US keyboard layout's virtual key codes, the same ones the
shortcut recorder captures. Shifted punctuation is written with `shift`:
Gmail's `#` is `shift+3`, and `+` is `shift+=`.

Quote chords that YAML would otherwise misread, such as `"cmd+["`,
`"cmd+]"` and `"cmd+,"`.

## Scope: app or website

Each imported macro remembers its pack and scope (`packName`, `appBundleID`,
`appName`, `website` in the configuration YAML). Macros without a scope
behave exactly as before: the keystrokes go to whatever app is frontmost.

When a scoped macro runs, playback first brings the scope to the front as a
prefix step in the same serial keyboard lane, then plays the keystrokes:

- **App scope** activates the app, launching it if it is not running, and
  waits (bounded) for it to be frontmost and finished launching. If the app
  is already frontmost nothing is launched.
- **Website scope** opens the URL in the default browser and waits up to two
  seconds for that browser to be frontmost. When Chrome handles the URL, an
  open tab on the same site is reused instead of opening a new one, exactly
  as HUD website bookmarks do.

If focus moves to an unrelated app while waiting, or the scope never comes
to the front, nothing is typed. The usual inter-step delay applies between
the scope step and the first keystroke.

Gmail's single-key shortcuts (`c`, `e`, `/`, `j`, `k`, `g` then `i`…) only
work when keyboard shortcuts are turned on in Gmail's settings. The bundled
Gmail pack says so in its `notes`, which the import confirmation shows.

## Importing

There is one import path, offered in two places:

- **Settings → Actions → Add action → Import macro pack…** opens a file
  chooser for `.yaml`/`.yml` files. **Add action → Built-in packs** lists the
  packs shipped with the app (Slack, Google Chrome, Gmail).
- In the **Choose an action** picker, the **Macros** tab has **Add macro…**
  (opens the saved-action editor; the new macro is stored and then chosen as
  the picked action) and **Import macro pack…** (the same import; the
  imported macros appear in the list and the first is selected).

After an import an alert reads `Imported N macros from <pack> (M updated)`,
followed by the scope and the pack's notes.

Imported macros get deterministic ids,
`pack:<pack-name-slug>:<macro-name-slug>`, so importing the same pack again
updates its macros in place rather than duplicating them. A re-import keeps
any global hotkey you assigned to a macro and replaces its keystrokes, delay
and scope. Macros you created by hand are never touched.

Imported macros appear in the actions table under **Macros** with the pack
name as subgroup, and in the picker's Macros tab with the pack name and
scope in the detail text (for example `Slack pack · Cmd+K`).

## Exporting

In the actions table, open a pack macro's **⋯** menu and choose
**Export <pack> pack…**. Every macro sharing that pack name is written to one
pack file through a save panel. Packs hold keystroke-only macros; a macro
with an open-app step cannot be exported, and neither can a key outside the
chord vocabulary above.

## Where built-in packs live

Source: `Rotagivan/MacroPacks/*.yaml`. `Rotagivan/build.sh` copies the folder
to `Rotagivan.app/Contents/Resources/MacroPacks`, which the Built-in packs
menu reads at launch. A pack that fails to parse is skipped so it never
hides the others.

## Code map

- `Rotagivan/MacroPack.swift`: `KeyChord` (chord parser, key-code table,
  canonical formatting), `MacroPack` (parse, validate, `namedHotkeys()`,
  export `yaml()`, built-in discovery), `Array<NamedHotkey>.importing(_:)`.
- `Rotagivan/MacroPackImport.swift`: open/save panels, confirmation alerts
  and the picker's `ActionPickerMacroTools.live(store:)`.
- `Rotagivan/Models.swift`: `NamedHotkey.packName/appBundleID/appName/website`,
  `scope`, `MacroScope`.
- `Rotagivan/MacroPlayback.swift`: the scope prefix step and the website
  opener hook; `Rotagivan/BrowserURLDispatcher.swift` supplies the
  Chrome-aware opener.
- Tests: `Rotagivan/Tests/MacroPackTests.swift`.
