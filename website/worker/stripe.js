// Minimal Stripe REST client and webhook signature verification using Web
// Crypto, so the Worker needs no Stripe SDK or Node compatibility layer.
import { hex } from "./http.js";

const STRIPE_API = "https://api.stripe.com/v1";
export const SIGNATURE_TOLERANCE_SECONDS = 300;

// Encode nested objects with Stripe's bracket syntax: a[b][0]=c.
export function formEncode(value, prefix = "", out = new URLSearchParams()) {
  if (value === undefined || value === null) return out;
  if (Array.isArray(value)) {
    value.forEach((item, index) => formEncode(item, `${prefix}[${index}]`, out));
  } else if (typeof value === "object") {
    for (const [key, item] of Object.entries(value)) {
      formEncode(item, prefix ? `${prefix}[${key}]` : key, out);
    }
  } else {
    out.append(prefix, String(value));
  }
  return out;
}

export async function stripeRequest(env, method, path, params, fetcher = fetch) {
  const init = {
    method,
    headers: { authorization: `Bearer ${env.STRIPE_SECRET_KEY}` },
  };
  // Without an explicit version Stripe uses the account's default API version.
  if (env.STRIPE_API_VERSION) init.headers["stripe-version"] = env.STRIPE_API_VERSION;
  if (params) {
    init.headers["content-type"] = "application/x-www-form-urlencoded";
    init.body = formEncode(params).toString();
  }
  const response = await fetcher(`${STRIPE_API}${path}`, init);
  const body = await response.json().catch(() => ({}));
  if (!response.ok) {
    const message = body?.error?.message || `Stripe request failed (${response.status}).`;
    const err = new Error(message);
    err.status = response.status;
    throw err;
  }
  return body;
}

function timingSafeEqual(a, b) {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

export async function signStripePayload(secret, timestamp, payload) {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const mac = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`${timestamp}.${payload}`));
  return hex(mac);
}

// Verifies a `Stripe-Signature` header (t=...,v1=...) against the raw body.
// Returns the parsed event, or throws with a short reason.
export async function verifyStripeEvent(payload, header, secret, now = Date.now() / 1000) {
  if (!secret) throw new Error("webhook secret is not configured");
  if (!header) throw new Error("missing Stripe-Signature header");
  let timestamp = null;
  const signatures = [];
  for (const part of header.split(",")) {
    const [key, value] = part.trim().split("=", 2);
    if (key === "t") timestamp = value;
    if (key === "v1" && value) signatures.push(value);
  }
  if (!timestamp || !/^\d+$/.test(timestamp) || signatures.length === 0) {
    throw new Error("malformed Stripe-Signature header");
  }
  if (Math.abs(now - Number(timestamp)) > SIGNATURE_TOLERANCE_SECONDS) {
    throw new Error("signature timestamp outside tolerance");
  }
  const expected = await signStripePayload(secret, timestamp, payload);
  if (!signatures.some((signature) => timingSafeEqual(signature, expected))) {
    throw new Error("signature mismatch");
  }
  return JSON.parse(payload);
}
