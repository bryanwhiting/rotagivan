// Small response helpers shared by the Worker routes.
export function json(body, status = 200, headers = {}) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
      ...headers,
    },
  });
}

export function error(status, code, message, extra = {}) {
  return json({ error: code, message, ...extra }, status);
}

export async function readJSON(request, limit = 16 * 1024) {
  const text = await request.text();
  if (text.length > limit) throw new HttpError(413, "body_too_large", "Request body is too large.");
  if (!text) return {};
  try {
    const value = JSON.parse(text);
    if (value && typeof value === "object" && !Array.isArray(value)) return value;
  } catch {}
  throw new HttpError(400, "invalid_json", "Request body must be a JSON object.");
}

export class HttpError extends Error {
  constructor(status, code, message) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

export function base64url(bytes) {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function fromBase64(value) {
  const normalized = value.replace(/-/g, "+").replace(/_/g, "/").replace(/\s+/g, "");
  const padded = normalized + "=".repeat((4 - (normalized.length % 4)) % 4);
  const binary = atob(padded);
  return Uint8Array.from(binary, (c) => c.charCodeAt(0));
}

export function hex(bytes) {
  return [...new Uint8Array(bytes)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export async function sha256Hex(text) {
  return hex(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text)));
}
