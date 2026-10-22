# Rota 60-second tour

Output: `website/public/rota-tour.mp4` (H.264, 1280x800, 30 fps, no audio) and
`website/public/rota-tour-poster.jpg`. Captions are burned in, so the video
works muted and there is no narration track; the voice-over column below is for
a future narrated cut and for anyone reading the video out loud.

Everything on screen is recorded from the website's interactive demo
(`src/components/Demo.astro` + `src/scripts/demo.ts`), driven by
`video/record.mjs` and assembled by `video/assemble.mjs`.

## Script

Times are on the finished video (each cut is a 0.5 s crossfade, so segments
overlap by half a second).

| Time | Shot | Voice-over | Burned-in caption |
| --- | --- | --- | --- |
| 0:00–0:03.5 | Hook card | Your Mac, one tap away. | **Rota** — Your Mac, one tap away. |
| 0:03–0:09 | Tap | Tap the trackpad… and a wheel appears right under your fingers. | Tap the trackpad. / A wheel of your apps, windows, tabs and macros appears under your fingers. |
| 0:08.5–0:16.5 | Wheel | Eight tiles, each one yours. Apps, websites, windows, tabs, macros. Nest groups. Pick a theme. | Eight tiles. Each one yours. / Apps, websites, windows, tabs, macros. Nest groups. Pick a theme. |
| 0:16–0:18 | Chapter card | — | ▥ Window tiling |
| 0:17.5–0:23.5 | Window tiling | Halves, thirds, quarters, or fill the desktop, from a tile or a hotkey you assign. | Halves, thirds, quarters, fill the desktop. / From a tile, or a hotkey you assign. |
| 0:23–0:24.5 | Chapter card | — | ◈ Chrome tabs |
| 0:24–0:29 | Chrome tabs | Your open Chrome tabs, most recent first. Bookmarks too. | Your open Chrome tabs, most recent first. / Bookmarks too. Slack channels too. |
| 0:28.5–0:30.5 | Chapter card | — | ⌘ Macros |
| 0:30–0:39 | Macros | Chain keystrokes and app launches into a named macro. One tile runs the whole routine. | Chain keystrokes and app launches into a macro. / One tile runs the whole routine. |
| 0:38.5–0:40 | Chapter card | — | ≡ Settings sync |
| 0:39.5–0:45.5 | Sync / local file | Your setup follows you: encrypted cloud sync, or a plain settings file in a folder you pick. | Encrypted cloud sync. / Or a plain settings.yaml in a folder you pick. |
| 0:45–0:47 | Chapter card | — | ≋ Voice mode |
| 0:46.5–0:53.5 | Voice mode | Say “open my browser”. Rota matches it against your own actions. Nothing runs until you confirm. | Say “open my browser”. / Rota shows the best three matches. Nothing runs until you confirm. |
| 0:53–0:58 | CTA card | Rota. Free for Mac. | rota.silvermine.dev · Free download |

Running time: 58.0 s (ffprobe), 1280x800, 30 fps, about 2.5 MB.

## Shot list

1. **Hook card.** Dark HUD background, light-blue glass ring, “Rota”,
   lede. 3.5 s.
2. **Tap.** Demo desktop with the wheel hidden. A tap ripple at the wheel's
   centre, the wheel pops in, slow push-in toward the wheel. 6 s.
3. **Wheel.** Zoomed on the wheel. Tiles 1 through 8 light up in turn (the
   demo's keys 1–8), one every 0.7 s. 8 s.
4. **Chapter card: Window tiling.** 1.8 s.
5. **Window tiling.** Tile 3 (Windows) selected; the demo window snaps to the
   left half, then the top-left quarter. 6 s.
6. **Chapter card: Chrome tabs.** 1.8 s.
7. **Chrome tabs.** Tile 2 (Browser) selected; a mock tab list with favicons
   and “most recent first” ordering appears beside the wheel. 5 s.
8. **Chapter card: Macros.** 1.8 s.
9. **Macros.** “Play a workflow” pressed; the demo's four-step tour (Apps →
   Browser → Windows → Focus) plays with the step counter. 9 s.
10. **Chapter card: Settings sync.** 1.8 s.
11. **Sync / local file.** A settings card over the desktop: cloud (encrypted)
    on one side, `~/.config/rota/settings.yaml` on the other. 6 s.
12. **Chapter card: Voice mode.** 1.8 s.
13. **Voice mode.** Tile 5 (Voice) selected; a transcript bubble “open my
    browser” and the three suggested actions with the top one highlighted. 7 s.
14. **CTA card.** “rota.silvermine.dev · Free download”. 5 s.

Every cut is a 0.5 s crossfade (ffmpeg `xfade`). Title cards are rendered in
the browser with the system font (the local ffmpeg build has no `drawtext`),
screenshotted once and looped by ffmpeg.

## Rebuild

```sh
cd website && npm run build
python3 -m http.server 4323 --directory dist &
cd video && npm install && npm run record && npm run assemble
```

`record` writes PNG frames per segment to `video/out/`, `assemble` encodes
each segment, crossfades them and writes the mp4 and poster into `public/`.
