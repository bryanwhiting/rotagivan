// License keys and offline-verifiable Ed25519 entitlements.
import { base64url, fromBase64 } from "./http.js";

const ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"; // Crockford base32
export const LICENSE_PATTERN = /^ROTA(-[0-9A-HJKMNP-TV-Z]{5}){4}$/;
export const DEVICE_PATTERN = /^[A-Za-z0-9._-]{8,128}$/;

export function generateLicenseKey() {
  const bytes = crypto.getRandomValues(new Uint8Array(20));
  const chars = [...bytes].map((b) => ALPHABET[b & 31]);
  const groups = [];
  for (let i = 0; i < 20; i += 5) groups.push(chars.slice(i, i + 5).join(""));
  return `ROTA-${groups.join("-")}`;
}

export function normalizeLicenseKey(value) {
  return typeof value === "string" ? value.trim().toUpperCase() : "";
}

// LICENSE_SIGNING_KEY holds the base64 PKCS#8 Ed25519 private key printed by
// scripts/generate-license-keys.mjs.
export async function importSigningKey(secret) {
  if (!secret) throw new Error("LICENSE_SIGNING_KEY is not configured");
  return crypto.subtle.importKey("pkcs8", fromBase64(secret), { name: "Ed25519" }, true, ["sign"]);
}

export async function publicKeyBase64(privateKey) {
  // Derive the raw 32-byte public key from the private JWK's `x` member.
  const jwk = await crypto.subtle.exportKey("jwk", privateKey);
  return btoa(String.fromCharCode(...fromBase64(jwk.x)));
}

export async function keyIdFor(publicKeyB64) {
  const digest = await crypto.subtle.digest("SHA-256", fromBase64(publicKeyB64));
  return base64url(new Uint8Array(digest).slice(0, 8));
}

// Signs the exact UTF-8 JSON bytes. Clients verify the signature over the
// base64url-decoded `payload` bytes before parsing them.
export async function signEntitlement(privateKey, claims) {
  const bytes = new TextEncoder().encode(JSON.stringify(claims));
  const signature = new Uint8Array(await crypto.subtle.sign({ name: "Ed25519" }, privateKey, bytes));
  return { payload: base64url(bytes), signature: base64url(signature) };
}

export async function verifyEntitlement(publicKeyB64, token) {
  const key = await crypto.subtle.importKey("raw", fromBase64(publicKeyB64), { name: "Ed25519" }, false, ["verify"]);
  const bytes = fromBase64(token.payload);
  const ok = await crypto.subtle.verify({ name: "Ed25519" }, key, fromBase64(token.signature), bytes);
  return ok ? JSON.parse(new TextDecoder().decode(bytes)) : null;
}
