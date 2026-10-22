# Macro packs

A macro pack is a YAML file holding a set of macros for one application or
website, written by hand or exported from Rota. Importing a pack adds
its macros to the saved-action library, where they can be assigned to any
hotkey, tap, swipe or HUD tile like any other macro.

Rota ships packs for Slack, Google Chrome, Gmail, Claude Code (the
Claude desktop app), Codex (the ChatGPT desktop app) and an AI terminal pack
that starts the `claude` and `codex` CLIs in iTerm. See
`Rota/MacroPacks/` for the files and copy one to start your own.

## File format

```yaml
format: rota-macro-pack/1
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
  - name: Start Claude Code in a new window   # a typed-text step
    steps: [cmd+n, {type: "claude"}, return]
    delay: 600
```

| Key | Required | Meaning |
| --- | --- | --- |
| `format` | yes | Exactly `rota-macro-pack/1`. |
| `name` | yes | Pack name, up to 120 characters. Shown as the subgroup under Macros and in the picker. |
| `app` | no | Bundle identifier of the app that receives the keystrokes (contains a dot, at most 255 characters). |
| `appName` | no | Display name for the app. Only valid with `app`. Defaults to the pack name. |
| `website` | no | An `http(s)` URL with a host, at most 512 characters. A pack has `app` or `website`, never both. |
| `notes` | no | Up to 2000 characters, shown in the confirmation after import. |
| `macros` | yes | 1–500 entries. Each has `name` (unique within the pack) and either `keys` (one chord) or `steps` (1–32 steps, each a chord or a typed-text mapping), plus optional `delay` (0–2000 ms). |

## Typed-text steps

A step written as the mapping `{type: "…"}` types its text into the
frontmost app instead of pressing a chord. The text is 1–512 characters with
no control characters; a newline inside the text presses Return. Typing is
posted as unicode keyboard events, so it is independent of the keyboard
layout and works in terminals, chat boxes and editors alike. The usual
inter-step `delay` applies before and after the text, and playback stops if
focus leaves the target app while typing. `keys` always names one chord; a
macro that only types text is written as `steps: [{type: "…"}]`.

Typed text is also available in the saved-action editor (**Add typed text**)
and round-trips through export. Saved configurations store it as a
`sequence` step with `kind: text` and `text`.

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
  packs shipped with the app (AI terminal, Claude Code, Codex, Gmail, Google
  Chrome, Slack).
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
pack file through a save panel. Packs hold keystroke and typed-text macros; a
macro with an open-app step cannot be exported, and neither can a key outside
the chord vocabulary above.

## AI session packs

- **Claude Code** (`claude-code.yaml`, app `com.anthropic.claudefordesktop`):
  the Claude desktop app's menu shortcuts. `Cmd+N` starts a new Claude Code
  session while the Code view is showing (a new chat in the chat view; the
  app has no shortcut for Go → Code), `Ctrl+Cmd+\` / `Ctrl+Cmd+-` open a
  session in a split, `Shift+Cmd+O` opens a folder, `Shift+Cmd+K` searches
  sessions. "New session and ask for a plan" types a prompt without sending
  it.
- **Codex** (`codex.yaml`, app `com.openai.codex`): the ChatGPT desktop app,
  which hosts Codex. `Cmd+N` new chat, `Shift+Cmd+N` temporary chat, `Cmd+O`
  opens a folder for Codex, `Ctrl+`` opens the terminal panel.
- **AI terminal** (`ai-terminal.yaml`, app `com.googlecode.iterm2`): opens a
  new iTerm window or tab, types `claude`, `claude --continue`,
  `claude --resume`, `codex` or `codex resume` and presses Return, with a
  600 ms step delay so the shell is ready. Copy the file and set
  `app: com.apple.Terminal` for Terminal.app.

The shortcuts were read from each app's menu bar through Accessibility; the
same walk powers the launcher's menu search (`LauncherMenuCatalog.scan`).

## Where built-in packs live

Source: `Rota/MacroPacks/*.yaml`. `Rota/build.sh` copies the folder
to `Rota.app/Contents/Resources/MacroPacks`, which the Built-in packs
menu reads at launch. A pack that fails to parse is skipped so it never
hides the others.

## Code map

- `Rota/MacroPack.swift`: `KeyChord` (chord parser, key-code table,
  canonical formatting), `MacroPack` (parse, validate, `namedHotkeys()`,
  export `yaml()`, built-in discovery), `Array<NamedHotkey>.importing(_:)`.
- `Rota/MacroPackImport.swift`: open/save panels, confirmation alerts
  and the picker's `ActionPickerMacroTools.live(store:)`.
- `Rota/Models.swift`: `NamedHotkey.packName/appBundleID/appName/website`,
  `scope`, `MacroScope`.
- `Rota/MacroPlayback.swift`: the scope prefix step, the website
  opener hook and the `type` hook for text steps; `Rota/EventPoster.swift`
  builds the unicode keyboard events (`textEvents`);
  `Rota/BrowserURLDispatcher.swift` supplies the Chrome-aware opener.
- Tests: `Rota/Tests/MacroPackTests.swift`,
  `Rota/Tests/MacroPlaybackTests.swift`.
