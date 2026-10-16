// Release downloads served from the private R2 bucket bound as RELEASES.
// The release script uploads versioned files under releases/ and writes
// latest.json last, so the manifest never points at a missing file.
import { error } from "./http.js";

const SAFE_NAME = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;
const TYPES = {
  dmg: "application/x-apple-diskimage",
  zip: "application/zip",
  json: "application/json; charset=utf-8",
  txt: "text/plain; charset=utf-8",
};

export async function readManifest(env) {
  const object = await env.RELEASES.get("latest.json");
  if (!object) return null;
  try {
    return JSON.parse(await object.text());
  } catch {
    return null;
  }
}

export async function handleLatestJSON(request, env) {
  const object = await env.RELEASES.get("latest.json");
  if (!object) return error(404, "no_release", "No release has been published yet.");
  return new Response(request.method === "HEAD" ? null : object.body, {
    headers: {
      "content-type": TYPES.json,
      "cache-control": "public, max-age=60, must-revalidate",
      "access-control-allow-origin": "*",
      etag: object.httpEtag,
    },
  });
}

export async function handleLatestDownload(request, env, format = "dmg") {
  const manifest = await readManifest(env);
  const target = format === "zip" ? manifest?.zip?.url : manifest?.url;
  if (!target) return error(404, "no_release", "No release has been published yet.");
  const location = new URL(target, request.url);
  // Only ever redirect to our own versioned files.
  if (!location.pathname.startsWith("/releases/")) return error(500, "bad_manifest", "Release manifest is invalid.");
  return new Response(null, {
    status: 302,
    headers: { location: location.pathname, "cache-control": "no-store" },
  });
}

export async function handleReleaseFile(request, env, name) {
  if (!SAFE_NAME.test(name)) return error(404, "not_found", "Release file not found.");
  const key = `releases/${name}`;
  const isHead = request.method === "HEAD";
  const object = isHead
    ? await env.RELEASES.head(key)
    : await env.RELEASES.get(key, { range: request.headers, onlyIf: request.headers });
  if (!object) return error(404, "not_found", "Release file not found.");
  const headers = new Headers();
  object.writeHttpMetadata(headers);
  const extension = name.split(".").pop().toLowerCase();
  headers.set("content-type", TYPES[extension] ?? "application/octet-stream");
  headers.set("etag", object.httpEtag);
  headers.set("accept-ranges", "bytes");
  // Versioned names never change contents.
  headers.set("cache-control", "public, max-age=31536000, immutable");
  if (extension === "dmg" || extension === "zip") {
    headers.set("content-disposition", `attachment; filename="${name}"`);
  }
  if (isHead) {
    headers.set("content-length", String(object.size));
    return new Response(null, { headers });
  }
  if (!("body" in object) || !object.body) {
    // onlyIf precondition failed.
    return new Response(null, { status: 304, headers });
  }
  if (object.range && request.headers.has("range")) {
    const range = object.range;
    const length = "suffix" in range ? Math.min(range.suffix, object.size) : (range.length ?? object.size - (range.offset ?? 0));
    const offset = "suffix" in range ? object.size - length : (range.offset ?? 0);
    headers.set("content-range", `bytes ${offset}-${offset + length - 1}/${object.size}`);
    headers.set("content-length", String(length));
    return new Response(object.body, { status: 206, headers });
  }
  headers.set("content-length", String(object.size));
  return new Response(object.body, { headers });
}
