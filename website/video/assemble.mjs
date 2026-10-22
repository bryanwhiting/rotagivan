// Turns the frames and title cards from record.mjs into public/rota-tour.mp4
// (H.264, yuv420p, faststart) with 0.5 s crossfades, plus the poster jpg.
//   FFMPEG=/opt/homebrew/bin/ffmpeg  (optional)

import { execFileSync } from "node:child_process";
import { readFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const OUT = join(here, "out");
const PUBLIC = join(here, "..", "public");
const FFMPEG = process.env.FFMPEG ?? "/opt/homebrew/bin/ffmpeg";
const FFPROBE = process.env.FFPROBE ?? FFMPEG.replace(/ffmpeg$/, "ffprobe");

const { fps, fade, segments } = JSON.parse(await readFile(join(OUT, "manifest.json"), "utf8"));
const ff = (args) => execFileSync(FFMPEG, ["-hide_banner", "-loglevel", "error", "-y", ...args], { stdio: "inherit" });

// 1. One intermediate clip per segment, all with the same fps/pixel format so xfade can join them.
const clips = [];
for (const seg of segments) {
  const clip = join(OUT, `${seg.id}.mp4`);
  const input = seg.type === "card"
    ? ["-loop", "1", "-framerate", String(fps), "-t", String(seg.dur), "-i", seg.path]
    : ["-framerate", String(fps), "-i", join(seg.path, "f%05d.png")];
  ff([...input, "-c:v", "libx264", "-preset", "fast", "-crf", "15", "-pix_fmt", "yuv420p", "-r", String(fps), clip]);
  clips.push({ ...seg, clip });
}

// 2. Crossfade chain. offset_k is where the k-th transition starts on the output timeline.
const inputs = clips.flatMap((c) => ["-i", c.clip]);
let filter = "";
let last = "[0:v]";
let offset = 0;
for (let i = 1; i < clips.length; i++) {
  offset += clips[i - 1].dur - fade;
  const out = i === clips.length - 1 ? "[v]" : `[v${i}]`;
  filter += `${last}[${i}:v]xfade=transition=fade:duration=${fade}:offset=${offset.toFixed(3)}${out};`;
  last = out;
}
filter = filter.replace(/;$/, "");
const mp4 = join(PUBLIC, "rota-tour.mp4");
ff([...inputs, "-filter_complex", filter, "-map", "[v]", "-c:v", "libx264", "-preset", "slow", "-crf", "21",
  "-profile:v", "high", "-level", "4.1", "-pix_fmt", "yuv420p", "-movflags", "+faststart", "-r", String(fps), "-an", mp4]);

// 3. Poster: the first frame.
const poster = join(PUBLIC, "rota-tour-poster.jpg");
ff(["-i", mp4, "-frames:v", "1", "-q:v", "3", poster]);

const probe = execFileSync(FFPROBE, ["-v", "error", "-show_entries", "format=duration,size", "-of", "default=nw=1", mp4]).toString();
console.log(mp4);
console.log(probe.trim());
console.log(poster);
