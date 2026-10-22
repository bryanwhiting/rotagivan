// Records the 60-second tour from the website's interactive demo.
//
// Renders deterministic frames: for every 1/30 s the script sets the stage
// state (zoom, captions, overlays, selected tile) in the page and takes a
// screenshot, so timing does not depend on how fast the browser renders.
// Title cards are rendered in the browser too (system font) and
// screenshotted once. assemble.mjs turns the frames into the mp4.
//
// Usage: serve the built site first (see script.md), then `npm run record`.
//   SITE=http://127.0.0.1:4323  CHROMIUM=/path/to/chrome  (both optional)

import { chromium } from "playwright";
import { mkdir, rm, writeFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const OUT = join(here, "out");
const SITE = process.env.SITE ?? "http://127.0.0.1:4323/";
const FPS = 30;
const W = 1280;
const H = 800;
const FADE = 0.5; // crossfade length used by assemble.mjs; segments overlap by this much

// --- easing / tween helpers -------------------------------------------------
const clamp = (x, a = 0, b = 1) => Math.min(b, Math.max(a, x));
const easeInOut = (x) => (x < 0.5 ? 4 * x * x * x : 1 - Math.pow(-2 * x + 2, 3) / 2);
const easeOut = (x) => 1 - Math.pow(1 - x, 3);
const tw = (t, t0, t1, a, b, ease = easeInOut) => a + (b - a) * ease(clamp((t - t0) / (t1 - t0)));
const lerpPt = (t, t0, t1, a, b) => ({ x: tw(t, t0, t1, a.x, b.x), y: tw(t, t0, t1, a.y, b.y) });
// Caption with a 0.3 s fade at each end. `lines` = [{ from, to, text }].
function caption(t, lines) {
  for (const l of lines) {
    if (t >= l.from && t < l.to) {
      const a = Math.min(clamp((t - l.from) / 0.3), clamp((l.to - t) / 0.3));
      return { text: l.text, alpha: a };
    }
  }
  return { text: "", alpha: 0 };
}

// --- page side ---------------------------------------------------------------
const STAGE_CSS = `
  header, .footer, .skip, .section, .works-with, .hero > :not(#playground),
  .demo-disclaimer, .demo-label { display: none !important; }
  html, body { margin: 0; background: #121214 !important; overflow: hidden !important; }
  .hero { padding: 0 !important; margin: 0 !important; }
  /* Fixed and centred (30px above centre so the caption has room); top is set from the measured height. */
  #playground { position: fixed; left: 50%; width: 760px; margin-left: -380px; transform-origin: 50% 50%; will-change: transform; }
  .demo-shell { margin: 0 !important; width: 760px; }
  .demo-toast { transition: none; }
  .demo-desktop.vo-has-card .demo-toast { left: 384px; }
  .demo-desktop { position: relative; }
  .demo-window { overflow: hidden; }
  .wheel { transform-origin: 50% 50% !important; }
  *, *::before, *::after { transition: none !important; animation: none !important; }
  :focus-visible { outline: none !important; }

  #vo-ripple { position: absolute; width: 0; height: 0; pointer-events: none; z-index: 5; }
  #vo-ripple i { position: absolute; left: -40px; top: -40px; width: 80px; height: 80px;
    border-radius: 50%; border: 2px solid #94ccff; box-shadow: 0 0 24px rgba(148,204,255,.6); }

  .vo-card { position: absolute; left: 24px; top: 282px; width: 346px; padding: 12px 14px;
    background: rgba(26,26,28,.94); color: #f2f2f4; border-radius: 12px;
    border: 1px solid rgba(255,255,255,.09); box-shadow: 0 16px 40px rgba(0,0,0,.45);
    font: 12px/1.35 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", Helvetica, Arial, sans-serif;
    opacity: 0; z-index: 4; }
  .vo-card .k { font-size: 10px; letter-spacing: .08em; color: #9d9da3; margin-bottom: 8px; }
  .vo-row { display: flex; align-items: center; gap: 10px; padding: 5px 8px; border-radius: 7px; }
  .vo-row + .vo-row { margin-top: 2px; }
  .vo-row .dot { width: 14px; height: 14px; border-radius: 4px; flex: none; }
  .vo-row .t { flex: 1; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .vo-row .m { color: #9d9da3; font-size: 11px; flex: none; }
  .vo-row.hot { background: rgba(148,204,255,.26); box-shadow: inset 0 0 0 1px rgba(148,204,255,.55); }
  .vo-row kbd { font-size: 10px; color: #94ccff; }
  .vo-bubble { display: inline-block; padding: 8px 12px; margin-bottom: 10px; border-radius: 12px;
    background: #2c2c30; font-size: 15px; }
  .vo-bubble .cur { display: inline-block; width: 2px; height: 15px; background: #94ccff; vertical-align: -2px; margin-left: 1px; }
  .vo-cols { display: grid; grid-template-columns: 1fr 1fr; gap: 10px; }
  .vo-col { padding: 10px; border-radius: 9px; background: #26262a; border: 1px solid rgba(255,255,255,.09); }
  .vo-col b { display: block; font-size: 13px; margin: 6px 0 2px; }
  .vo-col .big { font-size: 22px; color: #94ccff; line-height: 1; }
  .vo-col .m { color: #9d9da3; font-size: 11px; }
  .vo-col code { font: 11px ui-monospace, "SF Mono", Menlo, monospace; color: #33b3bf; }

  #vo-cap { position: fixed; left: 0; right: 0; bottom: 20px; text-align: center; z-index: 50; pointer-events: none; }
  #vo-cap span { display: inline-block; max-width: 900px; padding: 12px 24px; border-radius: 12px;
    background: rgba(26,26,28,.92); border: 1px solid rgba(148,204,255,.35);
    box-shadow: 0 12px 40px rgba(0,0,0,.5), 0 0 0 1px rgba(255,255,255,.06);
    color: #f2f2f4; font: 500 25px/1.3 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", Helvetica, Arial, sans-serif; }

  #vo-card { position: fixed; inset: 0; z-index: 60; display: none; place-items: center; text-align: center;
    color: #f2f2f4; background:
      radial-gradient(ellipse at 50% 0%, rgba(148,204,255,.16), transparent 60%),
      linear-gradient(160deg, #22272f, #121214);
    font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", "SF Pro Text", "Helvetica Neue", Helvetica, Arial, sans-serif; }
  #vo-card .ring { display: grid; place-items: center; width: 132px; height: 132px; margin: 0 auto 26px;
    border-radius: 50%; background: rgba(148,204,255,.26); color: #94ccff; font-size: 58px;
    box-shadow: inset 0 0 0 1px rgba(148,204,255,.55), 0 0 60px rgba(148,204,255,.25); }
  #vo-card .ring img { width: 76px; height: 76px; }
  #vo-card h1 { margin: 0; font-size: 64px; font-weight: 700; letter-spacing: -0.02em; line-height: 1.05; }
  #vo-card h2 { margin: 0; font-size: 44px; font-weight: 600; letter-spacing: -0.01em; }
  #vo-card .lede { margin: 16px 0 0; font-size: 28px; color: #c9c9ce; font-weight: 400; }
  #vo-card .cta { margin: 26px 0 0; font-size: 34px; font-weight: 600; color: #94ccff; }
  #vo-card .fine { margin: 16px 0 0; font-size: 20px; color: #9d9da3; }
`;

const STAGE_HTML = {
  tabs: `<div class="vo-card" id="vo-tabs">
    <div class="k">CHROME TABS · WORK PROFILE · MOST RECENT FIRST</div>
    <div class="vo-row hot"><i class="dot" style="background:#5b8def"></i><span class="t">Pull request #482 · review</span><span class="m">just now</span></div>
    <div class="vo-row"><i class="dot" style="background:#e06c75"></i><span class="t">Sprint board</span><span class="m">2 min</span></div>
    <div class="vo-row"><i class="dot" style="background:#9b7bf5"></i><span class="t">Design review</span><span class="m">9 min</span></div>
    <div class="vo-row"><i class="dot" style="background:#33b3bf"></i><span class="t">Quarterly plan</span><span class="m">1 h</span></div>
  </div>`,
  sync: `<div class="vo-card" id="vo-sync" style="width:470px">
    <div class="k">SETTINGS → SYNC &amp; BACKUP</div>
    <div class="vo-cols">
      <div class="vo-col"><span class="big">☁</span><b>Cloud sync</b><span class="m">AES-GCM, key from your password. Sign in on any Mac.</span></div>
      <div class="vo-col"><span class="big">▤</span><b>Local file</b><span class="m"><code>~/.config/rota/settings.yaml</code><br>Plain YAML. Read it, edit it, git it.</span></div>
    </div>
  </div>`,
  voice: `<div class="vo-card" id="vo-voice">
    <div class="k">VOICE MODE · LISTENING</div>
    <div class="vo-bubble"><span id="vo-said"></span><i class="cur"></i></div>
    <div id="vo-sugg" style="opacity:0">
      <div class="vo-row hot"><span class="t">◈ Browser · open in Chrome</span><kbd>↩ confirm</kbd></div>
      <div class="vo-row"><span class="t">⊞ Apps · favorite apps group</span><kbd>2</kbd></div>
      <div class="vo-row"><span class="t">◎ Focus · writing macro</span><kbd>3</kbd></div>
    </div>
  </div>`,
};

// Runs in the page once: hides the rest of the site, adds overlay nodes and
// the __apply(state) function used for every frame.
async function setupStage(page) {
  await page.addStyleTag({ content: STAGE_CSS });
  await page.evaluate((html) => {
    const desktop = document.querySelector(".demo-desktop");
    const ripple = document.createElement("div");
    ripple.id = "vo-ripple";
    ripple.innerHTML = "<i></i><i></i>";
    desktop.append(ripple);
    for (const h of Object.values(html)) desktop.insertAdjacentHTML("beforeend", h);
    const cap = document.createElement("div");
    cap.id = "vo-cap";
    cap.innerHTML = "<span></span>";
    document.body.append(cap);
    const card = document.createElement("div");
    card.id = "vo-card";
    document.body.append(card);

    const win = document.querySelector(".demo-window");
    const wheel = document.querySelector(".wheel");
    const stage = document.getElementById("playground");
    const center = document.querySelector(".wheel-center");
    stage.style.top = `calc(50% - ${Math.round(stage.offsetHeight / 2) + 30}px)`;
    // Geometry at zoom 1 (no transform yet): offsets from the stage centre.
    const sr = stage.getBoundingClientRect();
    const cr = center.getBoundingClientRect();
    const wr = win.getBoundingClientRect();
    const dr = desktop.getBoundingClientRect();
    window.__pts = {
      center: { x: 0, y: 0 },
      wheel: { x: cr.left + cr.width / 2 - (sr.left + sr.width / 2), y: cr.top + cr.height / 2 - (sr.top + sr.height / 2) },
      window: { x: wr.left + wr.width / 2 - (sr.left + sr.width / 2), y: wr.top + wr.height / 2 - (sr.top + sr.height / 2) },
      winBox: { top: wr.top - dr.top, left: wr.left - dr.left, width: wr.width, height: wr.height },
      desktop: { width: dr.width, height: dr.height },
    };
    ripple.style.left = `${cr.left + cr.width / 2 - dr.left}px`;
    ripple.style.top = `${cr.top + cr.height / 2 - dr.top}px`;

    window.__apply = (s) => {
      stage.style.transform = `translate(${-s.focus.x * s.zoom}px, ${-s.focus.y * s.zoom}px) scale(${s.zoom})`;
      wheel.style.opacity = String(s.wheel.alpha);
      wheel.style.transform = `scale(${s.wheel.scale})`;
      const rings = ripple.querySelectorAll("i");
      rings.forEach((r, i) => {
        if (s.ripple == null) { r.style.opacity = "0"; return; }
        const p = Math.min(1, Math.max(0, s.ripple - i * 0.18));
        r.style.opacity = String(p > 0 ? 1 - p : 0);
        r.style.transform = `scale(${0.3 + 1.5 * p})`;
      });
      if (s.win) {
        Object.assign(win.style, { top: `${s.win.top}px`, left: `${s.win.left}px`, width: `${s.win.width}px`, height: `${s.win.height}px`, transform: "none" });
      } else {
        win.style.cssText = "";
      }
      for (const id of ["vo-tabs", "vo-sync", "vo-voice"]) {
        document.getElementById(id).style.opacity = String(s.overlay?.id === id ? s.overlay.alpha : 0);
      }
      desktop.classList.toggle("vo-has-card", Boolean(s.overlay));
      if (s.voice) {
        document.getElementById("vo-said").textContent = s.voice.text;
        document.getElementById("vo-sugg").style.opacity = String(s.voice.suggest);
      }
      const span = cap.firstElementChild;
      span.textContent = s.caption.text;
      cap.style.opacity = String(s.caption.alpha);
      cap.style.transform = `translateY(${(1 - s.caption.alpha) * 8}px)`;
    };
    window.__card = (html) => {
      card.innerHTML = html;
      card.style.display = html ? "grid" : "none";
    };
    window.__click = (sel) => document.querySelector(sel).click();
    window.__toast = (text) => { document.querySelector("[data-status]").textContent = text; };
    window.__tourLabel = (text) => { document.querySelector("[data-tour]").textContent = text; };
  }, STAGE_HTML);
  return page.evaluate(() => window.__pts);
}

const base = (over = {}) => ({
  zoom: 1.18,
  focus: { x: 0, y: 0 },
  wheel: { alpha: 1, scale: 1 },
  ripple: null,
  win: null,
  overlay: null,
  voice: null,
  caption: { text: "", alpha: 0 },
  ...over,
});

// --- the timeline ------------------------------------------------------------
function timeline(pts) {
  const P = pts;
  const wheelFocus = { x: P.wheel.x * 0.5, y: P.wheel.y * 0.5 + 44 };
  const leftFocus = { x: P.window.x * 0.3, y: P.window.y * 0.25 };
  // Window trimmed so an overlay card fits under it without covering the toast.
  const shortWin = { ...P.winBox, height: 236 };
  const half = { top: 12, left: 12, width: P.desktop.width / 2 - 18, height: P.desktop.height - 64 };
  const quarter = { ...half, height: P.desktop.height / 2 - 18 };
  const box = (t, t0, t1, a, b) => ({
    top: tw(t, t0, t1, a.top, b.top), left: tw(t, t0, t1, a.left, b.left),
    width: tw(t, t0, t1, a.width, b.width), height: tw(t, t0, t1, a.height, b.height),
  });
  const chapter = (symbol, title) => ({
    type: "card", dur: 1.8,
    html: `<div><div class="ring">${symbol}</div><h2>${title}</h2></div>`,
  });
  const SAID = "open my browser";

  return [
    {
      name: "hook", type: "card", dur: 3.5,
      html: `<div><div class="ring"><img src="/favicon.svg" alt=""></div><h1>Rota</h1><p class="lede">Your Mac, one tap away.</p></div>`,
    },
    {
      name: "tap", dur: 6,
      events: [{ at: 0, run: ["reset"] }],
      frame: (t) => base({
        zoom: tw(t, 1.4, 3.2, 1.18, 1.36),
        focus: lerpPt(t, 1.4, 3.2, P.center, { x: wheelFocus.x * 0.8, y: wheelFocus.y * 0.8 }),
        wheel: { alpha: tw(t, 1.1, 1.45, 0, 1, easeOut), scale: tw(t, 1.1, 1.5, 0.7, 1, easeOut) },
        ripple: t >= 1.0 && t < 1.9 ? (t - 1.0) / 0.9 : null,
        caption: caption(t, [
          { from: 0.3, to: 2.9, text: "Tap the trackpad." },
          { from: 3.1, to: 6.2, text: "A wheel of your apps, windows, tabs and macros appears under your fingers." },
        ]),
      }),
    },
    {
      name: "wheel", dur: 8,
      events: ["focus", "browser", "windows", "music", "voice", "notes", "work", "apps"].map((k, i) => ({ at: 0.5 + 0.7 * i, run: ["select", k] })),
      frame: (t) => base({
        zoom: tw(t, 6.3, 7.6, 1.45, 1.22),
        focus: lerpPt(t, 6.3, 7.6, wheelFocus, { x: wheelFocus.x * 0.3, y: wheelFocus.y * 0.3 }),
        caption: caption(t, [
          { from: 0.2, to: 3.7, text: "Eight tiles. Each one yours." },
          { from: 3.9, to: 8.2, text: "Apps, websites, windows, tabs, macros. Nest groups. Pick a theme." },
        ]),
      }),
    },
    { name: "chapter-tiling", ...chapter("▥", "Window tiling") },
    {
      name: "tiling", dur: 6,
      events: [{ at: 0, run: ["reset"] }, { at: 0.4, run: ["select", "windows"] }],
      frame: (t) => base({
        zoom: 1.22,
        focus: leftFocus,
        win: t < 1.2 ? P.winBox : t < 3.4 ? box(t, 1.2, 1.65, P.winBox, half) : box(t, 3.4, 3.85, half, quarter),
        caption: caption(t, [
          { from: 0.3, to: 3.3, text: "Halves, thirds, quarters, fill the desktop." },
          { from: 3.5, to: 6.2, text: "From a tile, or a hotkey you assign." },
        ]),
      }),
    },
    { name: "chapter-tabs", ...chapter("◈", "Chrome tabs") },
    {
      name: "tabs", dur: 5,
      events: [{ at: 0, run: ["reset"] }, { at: 0.4, run: ["select", "browser"] }],
      frame: (t) => base({
        zoom: 1.22,
        focus: leftFocus,
        win: shortWin,
        overlay: { id: "vo-tabs", alpha: tw(t, 0.8, 1.2, 0, 1, easeOut) },
        caption: caption(t, [
          { from: 0.3, to: 2.9, text: "Your open Chrome tabs, most recent first." },
          { from: 3.1, to: 5.2, text: "Bookmarks too. Slack channels too." },
        ]),
      }),
    },
    { name: "chapter-macros", ...chapter("⌘", "Macros") },
    {
      name: "macros", dur: 9,
      events: [
        { at: 0, run: ["reset"] },
        { at: 0.5, run: ["tour"] },
        { at: 2.4, run: ["step", "browser", "Step 2 of 4: project dashboard opened in browser"] },
        { at: 4.3, run: ["step", "windows", "Step 3 of 4: active window tiled to the left"] },
        { at: 6.2, run: ["step", "focus", "Step 4 of 4: writing app opened · focus shortcut sent"] },
        { at: 8.0, run: ["tourDone"] },
      ],
      frame: (t) => base({
        zoom: 1.18,
        focus: { x: 0, y: 0 },
        caption: caption(t, [
          { from: 0.3, to: 4.2, text: "Chain keystrokes and app launches into a macro." },
          { from: 4.4, to: 9.2, text: "One tile runs the whole routine." },
        ]),
      }),
    },
    { name: "chapter-sync", ...chapter("≡", "Settings sync") },
    {
      name: "sync", dur: 6,
      events: [{ at: 0, run: ["reset"] }, { at: 0.3, run: ["select", "work"] }],
      frame: (t) => base({
        zoom: 1.22,
        focus: leftFocus,
        win: shortWin,
        overlay: { id: "vo-sync", alpha: tw(t, 0.7, 1.1, 0, 1, easeOut) },
        caption: caption(t, [
          { from: 0.3, to: 2.9, text: "Encrypted cloud sync." },
          { from: 3.1, to: 6.2, text: "Or a plain settings.yaml in a folder you pick." },
        ]),
      }),
    },
    { name: "chapter-voice", ...chapter("≋", "Voice mode") },
    {
      name: "voice", dur: 7,
      events: [{ at: 0, run: ["reset"] }, { at: 0.4, run: ["select", "voice"] }],
      frame: (t) => base({
        zoom: 1.22,
        focus: leftFocus,
        win: shortWin,
        overlay: { id: "vo-voice", alpha: tw(t, 0.8, 1.2, 0, 1, easeOut) },
        voice: {
          text: SAID.slice(0, Math.round(tw(t, 1.3, 2.6, 0, SAID.length, (x) => x))),
          suggest: tw(t, 3.0, 3.4, 0, 1, easeOut),
        },
        caption: caption(t, [
          { from: 0.3, to: 3.3, text: "Say “open my browser”." },
          { from: 3.5, to: 7.2, text: "Rota shows the best three matches. Nothing runs until you confirm." },
        ]),
      }),
    },
    {
      name: "cta", type: "card", dur: 5,
      html: `<div><div class="ring"><img src="/favicon.svg" alt=""></div><h1>Rota</h1><p class="cta">rota.silvermine.dev · Free download</p><p class="fine">Free for Mac · Voice mode optional</p></div>`,
    },
  ];
}

async function runEvent(page, [kind, a, b]) {
  switch (kind) {
    case "reset":
      return page.evaluate(() => { window.__click("[data-reset]"); window.__tourLabel("Play a workflow ▷"); });
    case "select":
      return page.evaluate((k) => window.__click(`[data-action="${k}"]`), a);
    case "tour":
      // The demo's tour advances on real-time timers; the frames are not real
      // time, so stub the timer and advance the steps from the timeline.
      return page.evaluate(() => {
        window.__realSetTimeout = window.setTimeout;
        window.setTimeout = () => 0;
        window.__click("[data-tour]");
      });
    case "step":
      return page.evaluate(([k, status]) => {
        window.__click(`[data-action="${k}"]`);
        window.__toast(status);
        window.__tourLabel("Stop workflow ■");
      }, [a, b]);
    case "tourDone":
      return page.evaluate(() => {
        window.setTimeout = window.__realSetTimeout;
        window.__toast("Workflow complete. Your workspace is ready.");
        window.__tourLabel("Play a workflow ▷");
      });
  }
}

// --- main ---------------------------------------------------------------------
await rm(OUT, { recursive: true, force: true });
await mkdir(OUT, { recursive: true });

const browser = await chromium.launch({
  executablePath: process.env.CHROMIUM || undefined,
});
const page = await browser.newPage({
  viewport: { width: W, height: H },
  deviceScaleFactor: 1,
  colorScheme: "dark",
  reducedMotion: "reduce",
});
await page.goto(SITE, { waitUntil: "networkidle" });
await page.evaluate(() => document.fonts.ready);
const pts = await setupStage(page);
const segments = timeline(pts);

// Previews: ONLY=tap,wheel renders those segments; SAMPLE=15 renders every 15th frame.
const only = process.env.ONLY ? new Set(process.env.ONLY.split(",")) : null;
const sample = Number(process.env.SAMPLE ?? 1);

const manifest = [];
let index = 0;
for (const seg of segments) {
  index += 1;
  if (only && !only.has(seg.name)) continue;
  const id = `${String(index).padStart(2, "0")}-${seg.name}`;
  if (seg.type === "card") {
    await page.evaluate((html) => window.__card(html), seg.html);
    const path = join(OUT, `${id}.png`);
    await page.screenshot({ path, type: "png", animations: "disabled" });
    await page.evaluate(() => window.__card(""));
    manifest.push({ id, type: "card", dur: seg.dur, path });
    console.log(`${id}: card`);
    continue;
  }
  const dir = join(OUT, id);
  await mkdir(dir, { recursive: true });
  const frames = Math.round(seg.dur * FPS);
  const events = [...(seg.events ?? [])].sort((a, b) => a.at - b.at);
  let ev = 0;
  for (let f = 0; f < frames; f++) {
    const t = f / FPS;
    while (ev < events.length && events[ev].at <= t) {
      await runEvent(page, events[ev].run);
      ev += 1;
    }
    await page.evaluate((s) => window.__apply(s), seg.frame(t));
    if (f % sample === 0) await page.screenshot({ path: join(dir, `f${String(f).padStart(5, "0")}.png`), type: "png", animations: "disabled" });
  }
  manifest.push({ id, type: "frames", dur: frames / FPS, path: dir });
  console.log(`${id}: ${frames} frames`);
}
await browser.close();
await writeFile(join(OUT, "manifest.json"), JSON.stringify({ fps: FPS, width: W, height: H, fade: FADE, segments: manifest }, null, 2));
const total = manifest.reduce((s, m) => s + m.dur, 0) - FADE * (manifest.length - 1);
console.log(`segments: ${manifest.length}, expected duration ${total.toFixed(2)} s`);
if (!existsSync(join(OUT, "manifest.json"))) throw new Error("manifest not written");
