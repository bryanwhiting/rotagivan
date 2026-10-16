// Stripe Checkout, webhook fulfilment and license verification for Voice mode.
import { error, json, readJSON } from "./http.js";
import { stripeRequest, verifyStripeEvent } from "./stripe.js";
import {
  DEVICE_PATTERN,
  LICENSE_PATTERN,
  generateLicenseKey,
  importSigningKey,
  keyIdFor,
  normalizeLicenseKey,
  publicKeyBase64,
  signEntitlement,
} from "./license.js";

const ACTIVE = new Set(["active", "trialing"]);
const nowSeconds = () => Math.floor(Date.now() / 1000);
const intVar = (value, fallback) => {
  const parsed = Number.parseInt(value ?? "", 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
};

function siteURL(env, request) {
  return (env.SITE_URL || new URL(request.url).origin).replace(/\/$/, "");
}

// POST /api/checkout  {email?} -> {id, url}
export async function handleCheckout(request, env, fetcher = fetch) {
  if (!env.STRIPE_SECRET_KEY || !env.STRIPE_PRICE_ID_VOICE) {
    return error(503, "payments_not_configured", "Voice mode checkout is not available yet.");
  }
  const body = await readJSON(request);
  const mode = env.STRIPE_CHECKOUT_MODE === "payment" ? "payment" : "subscription";
  const site = siteURL(env, request);
  const params = {
    mode,
    line_items: [{ price: env.STRIPE_PRICE_ID_VOICE, quantity: 1 }],
    success_url: `${site}/purchase/success/?session_id={CHECKOUT_SESSION_ID}`,
    cancel_url: `${site}/pricing/?checkout=cancelled`,
    allow_promotion_codes: "true",
    metadata: { product: "rotagivan-voice" },
  };
  if (typeof body.email === "string" && /^[^\s@]+@[^\s@]+$/.test(body.email) && body.email.length <= 254) {
    params.customer_email = body.email;
  }
  if (mode === "payment") params.customer_creation = "always";
  try {
    const session = await stripeRequest(env, "POST", "/checkout/sessions", params, fetcher);
    return json({ id: session.id, url: session.url });
  } catch (err) {
    console.error("checkout session failed", err.message);
    return error(502, "checkout_failed", "Could not start checkout. Please try again.");
  }
}

// GET /api/checkout/session?session_id=cs_... -> license for the success page.
// Session ids are unguessable and only returned to the paying browser.
export async function handleCheckoutSession(request, env) {
  const id = new URL(request.url).searchParams.get("session_id") ?? "";
  if (!/^cs_[A-Za-z0-9_]{8,255}$/.test(id)) return error(400, "invalid_session", "Missing or invalid session id.");
  const row = await env.DB.prepare(
    "SELECT license_key, status FROM licenses WHERE stripe_checkout_session_id = ?",
  ).bind(id).first();
  if (!row) return json({ status: "pending" }, 202);
  return json({ status: row.status, licenseKey: row.license_key });
}

// POST /api/stripe/webhook
export async function handleWebhook(request, env) {
  const payload = await request.text();
  let event;
  try {
    event = await verifyStripeEvent(payload, request.headers.get("stripe-signature"), env.STRIPE_WEBHOOK_SECRET);
  } catch (err) {
    return error(400, "invalid_signature", `Webhook rejected: ${err.message}.`);
  }
  const seen = await env.DB.prepare(
    "INSERT OR IGNORE INTO stripe_events (id, type, received_at) VALUES (?, ?, ?)",
  ).bind(event.id, event.type, nowSeconds()).run();
  if (seen.meta?.changes === 0) return json({ received: true, duplicate: true });
  try {
    await applyEvent(event, env);
  } catch (err) {
    // Let Stripe retry: forget the event so the retry is processed.
    await env.DB.prepare("DELETE FROM stripe_events WHERE id = ?").bind(event.id).run();
    console.error("webhook processing failed", event.type, err.message);
    return error(500, "processing_failed", "Webhook processing failed.");
  }
  return json({ received: true });
}

async function applyEvent(event, env) {
  const object = event.data?.object ?? {};
  const now = nowSeconds();
  switch (event.type) {
    case "checkout.session.completed":
    case "checkout.session.async_payment_succeeded": {
      if (!["paid", "no_payment_required"].includes(object.payment_status)) return; // async payment pending
      if (object.metadata?.product !== "rotagivan-voice") return; // not created by /api/checkout
      await env.DB.prepare(
        `INSERT INTO licenses (license_key, status, entitlements, email, stripe_customer_id,
           stripe_checkout_session_id, stripe_subscription_id, stripe_payment_intent_id, mode, created_at, updated_at)
         VALUES (?, 'active', '["voice"]', ?, ?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT (stripe_checkout_session_id) DO NOTHING`,
      ).bind(
        generateLicenseKey(),
        object.customer_details?.email ?? object.customer_email ?? null,
        object.customer ?? null,
        object.id,
        object.subscription ?? null,
        object.payment_intent ?? null,
        object.mode === "payment" ? "payment" : "subscription",
        now,
        now,
      ).run();
      return;
    }
    case "customer.subscription.created":
    case "customer.subscription.updated":
    case "customer.subscription.deleted": {
      const status = event.type === "customer.subscription.deleted" ? "canceled" : object.status;
      await env.DB.prepare(
        "UPDATE licenses SET status = ?, updated_at = ? WHERE stripe_subscription_id = ?",
      ).bind(ACTIVE.has(status) ? "active" : status, now, object.id).run();
      return;
    }
    case "charge.refunded": {
      if (!object.payment_intent || !object.refunded) return; // partial refunds keep the license
      await env.DB.prepare(
        "UPDATE licenses SET status = 'refunded', updated_at = ? WHERE stripe_payment_intent_id = ?",
      ).bind(now, object.payment_intent).run();
      return;
    }
    default:
      return; // Unhandled event types are acknowledged and ignored.
  }
}

// POST /api/license/verify {licenseKey, deviceId} -> signed entitlement
export async function handleLicenseVerify(request, env) {
  const body = await readJSON(request);
  const licenseKey = normalizeLicenseKey(body.licenseKey);
  const deviceId = typeof body.deviceId === "string" ? body.deviceId : "";
  if (!LICENSE_PATTERN.test(licenseKey)) return error(400, "invalid_license_key", "License key format is invalid.");
  if (!DEVICE_PATTERN.test(deviceId)) return error(400, "invalid_device_id", "Device id must be 8-128 characters of A-Z, a-z, 0-9, '.', '_' or '-'.");
  let signingKey;
  try {
    signingKey = await importSigningKey(env.LICENSE_SIGNING_KEY);
  } catch {
    return error(503, "licensing_not_configured", "License verification is not available yet.");
  }
  const license = await env.DB.prepare(
    "SELECT license_key, status, entitlements FROM licenses WHERE license_key = ?",
  ).bind(licenseKey).first();
  if (!license) return error(404, "license_not_found", "License key not found.", { valid: false });
  if (license.status !== "active") {
    return error(403, "license_inactive", `License is ${license.status}.`, { valid: false, status: license.status });
  }
  const now = nowSeconds();
  const existing = await env.DB.prepare(
    "SELECT device_id FROM activations WHERE license_key = ? AND device_id = ?",
  ).bind(licenseKey, deviceId).first();
  if (existing) {
    await env.DB.prepare("UPDATE activations SET last_seen = ? WHERE license_key = ? AND device_id = ?")
      .bind(now, licenseKey, deviceId).run();
  } else {
    const maxDevices = intVar(env.LICENSE_MAX_DEVICES, 3);
    const count = await env.DB.prepare("SELECT COUNT(*) AS n FROM activations WHERE license_key = ?")
      .bind(licenseKey).first();
    if ((count?.n ?? 0) >= maxDevices) {
      return error(409, "device_limit", `This license is already active on ${maxDevices} Macs.`, { valid: false });
    }
    await env.DB.prepare(
      "INSERT INTO activations (license_key, device_id, first_seen, last_seen) VALUES (?, ?, ?, ?)",
    ).bind(licenseKey, deviceId, now, now).run();
  }
  let entitlements;
  try {
    entitlements = JSON.parse(license.entitlements);
  } catch {
    entitlements = ["voice"];
  }
  const publicKey = await publicKeyBase64(signingKey);
  const claims = {
    v: 1,
    iss: "rota.silvermine.dev",
    sub: licenseKey,
    deviceId,
    entitlements,
    iat: now,
    exp: now + intVar(env.ENTITLEMENT_TTL_DAYS, 7) * 86400,
  };
  const token = await signEntitlement(signingKey, claims);
  return json({ valid: true, ...claims, entitlement: { ...token, alg: "Ed25519", kid: await keyIdFor(publicKey) } });
}

// GET /api/license/public-key -> the key the app embeds (for checking setup).
export async function handlePublicKey(env) {
  try {
    const key = await importSigningKey(env.LICENSE_SIGNING_KEY);
    const publicKey = await publicKeyBase64(key);
    return json({ alg: "Ed25519", kid: await keyIdFor(publicKey), publicKey }, 200, { "cache-control": "public, max-age=300" });
  } catch {
    return error(503, "licensing_not_configured", "License verification is not available yet.");
  }
}
