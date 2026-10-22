import { test } from "node:test";
import assert from "node:assert/strict";
import { webcrypto } from "node:crypto";
import worker from "../worker/index.js";
import { signStripePayload, verifyStripeEvent, formEncode } from "../worker/stripe.js";
import { LICENSE_PATTERN, generateLicenseKey, verifyEntitlement } from "../worker/license.js";
import { handleCheckout } from "../worker/payments.js";
import { fakeD1, fakeR2 } from "./fake-env.js";

const WEBHOOK_SECRET = "whsec_test_secret";

async function signingKey() {
  const pair = await webcrypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"]);
  return {
    secret: Buffer.from(await webcrypto.subtle.exportKey("pkcs8", pair.privateKey)).toString("base64"),
    publicKey: Buffer.from(await webcrypto.subtle.exportKey("raw", pair.publicKey)).toString("base64"),
  };
}

async function makeEnv(overrides = {}) {
  const keys = await signingKey();
  return {
    env: {
      DB: fakeD1(),
      RELEASES: fakeR2(),
      STRIPE_WEBHOOK_SECRET: WEBHOOK_SECRET,
      LICENSE_SIGNING_KEY: keys.secret,
      SITE_URL: "https://rota.example",
      ...overrides,
    },
    publicKey: keys.publicKey,
  };
}

const call = (env, path, init) => worker.fetch(new Request(`https://rota.example${path}`, init), env);

async function deliver(env, event, { secret = WEBHOOK_SECRET, timestamp = Math.floor(Date.now() / 1000) } = {}) {
  const payload = JSON.stringify(event);
  const signature = await signStripePayload(secret, timestamp, payload);
  return call(env, "/api/stripe/webhook", {
    method: "POST",
    headers: { "stripe-signature": `t=${timestamp},v1=${signature}` },
    body: payload,
  });
}

const completed = (id = "cs_test_1234567890", extra = {}) => ({
  id: `evt_${id}`,
  type: "checkout.session.completed",
  data: {
    object: {
      id,
      mode: "subscription",
      payment_status: "paid",
      customer: "cus_123",
      subscription: "sub_123",
      customer_details: { email: "buyer@example.com" },
      metadata: { product: "rotagivan-voice" },
      ...extra,
    },
  },
});

test("stripe signature verification accepts valid and rejects tampered, stale or missing signatures", async () => {
  const payload = '{"id":"evt_1"}';
  const t = 1_700_000_000;
  const sig = await signStripePayload("whsec_x", t, payload);
  assert.deepEqual(await verifyStripeEvent(payload, `t=${t},v1=${sig}`, "whsec_x", t + 10), { id: "evt_1" });
  assert.deepEqual(await verifyStripeEvent(payload, `t=${t},v1=deadbeef,v1=${sig}`, "whsec_x", t), { id: "evt_1" });
  await assert.rejects(verifyStripeEvent(payload + " ", `t=${t},v1=${sig}`, "whsec_x", t), /mismatch/);
  await assert.rejects(verifyStripeEvent(payload, `t=${t},v1=${sig}`, "whsec_other", t), /mismatch/);
  await assert.rejects(verifyStripeEvent(payload, `t=${t},v1=${sig}`, "whsec_x", t + 301), /tolerance/);
  await assert.rejects(verifyStripeEvent(payload, null, "whsec_x", t), /missing/);
  await assert.rejects(verifyStripeEvent(payload, "v1=abc", "whsec_x", t), /malformed/);
  await assert.rejects(verifyStripeEvent(payload, `t=${t},v1=${sig}`, "", t), /not configured/);
});

test("form encoding uses Stripe bracket syntax", () => {
  const encoded = formEncode({ mode: "payment", line_items: [{ price: "price_1", quantity: 1 }], metadata: { a: "b" } });
  assert.equal(decodeURIComponent(encoded.toString()), "mode=payment&line_items[0][price]=price_1&line_items[0][quantity]=1&metadata[a]=b");
});

test("license keys are well-formed and unique", () => {
  const keys = new Set(Array.from({ length: 200 }, generateLicenseKey));
  assert.equal(keys.size, 200);
  for (const key of keys) assert.match(key, LICENSE_PATTERN);
});

test("checkout reports not configured without Stripe secrets", async () => {
  const { env } = await makeEnv();
  const response = await call(env, "/api/checkout", { method: "POST", body: "{}" });
  assert.equal(response.status, 503);
  assert.equal((await response.json()).error, "payments_not_configured");
});

test("checkout creates a session for the configured price", async () => {
  const { env } = await makeEnv({ STRIPE_SECRET_KEY: "sk_test_x", STRIPE_PRICE_ID_VOICE: "price_voice" });
  let seen;
  const fetcher = async (url, init) => {
    seen = { url, init };
    return new Response(JSON.stringify({ id: "cs_test_abc", url: "https://checkout.stripe.com/c/pay/cs_test_abc" }));
  };
  const request = new Request("https://rota.example/api/checkout", { method: "POST", body: '{"email":"a@b.co"}' });
  const response = await handleCheckout(request, env, fetcher);
  assert.equal(response.status, 200);
  assert.equal((await response.json()).url, "https://checkout.stripe.com/c/pay/cs_test_abc");
  assert.equal(seen.url, "https://api.stripe.com/v1/checkout/sessions");
  assert.equal(seen.init.headers.authorization, "Bearer sk_test_x");
  const form = new URLSearchParams(seen.init.body);
  assert.equal(form.get("line_items[0][price]"), "price_voice");
  assert.equal(form.get("mode"), "subscription");
  assert.equal(form.get("customer_email"), "a@b.co");
  assert.equal(form.get("metadata[product]"), "rotagivan-voice");
  assert.equal(form.get("success_url"), "https://rota.example/purchase/success/?session_id={CHECKOUT_SESSION_ID}");
});

test("webhook rejects bad signatures and does not issue a license", async () => {
  const { env } = await makeEnv();
  const response = await deliver(env, completed(), { secret: "whsec_wrong" });
  assert.equal(response.status, 400);
  assert.equal(env.DB.raw.prepare("SELECT COUNT(*) AS n FROM licenses").get().n, 0);
});

test("purchase -> license -> signed entitlement -> cancellation", async () => {
  const { env, publicKey } = await makeEnv({ LICENSE_MAX_DEVICES: "2" });
  assert.equal((await deliver(env, completed())).status, 200);
  // Retried delivery is idempotent.
  assert.equal((await (await deliver(env, completed())).json()).duplicate, true);
  assert.equal(env.DB.raw.prepare("SELECT COUNT(*) AS n FROM licenses").get().n, 1);

  const session = await (await call(env, "/api/checkout/session?session_id=cs_test_1234567890")).json();
  assert.equal(session.status, "active");
  assert.match(session.licenseKey, LICENSE_PATTERN);

  const verify = (deviceId, licenseKey = session.licenseKey) =>
    call(env, "/api/license/verify", { method: "POST", body: JSON.stringify({ licenseKey, deviceId }) });

  const ok = await verify("device-AAAAAAAA");
  assert.equal(ok.status, 200);
  const body = await ok.json();
  assert.equal(body.valid, true);
  assert.deepEqual(body.entitlements, ["voice"]);
  const claims = await verifyEntitlement(publicKey, body.entitlement);
  assert.equal(claims.deviceId, "device-AAAAAAAA");
  assert.equal(claims.sub, session.licenseKey);
  assert.ok(claims.exp > claims.iat);
  // Tampered payload fails offline verification.
  const forged = Buffer.from(JSON.stringify({ ...claims, entitlements: ["voice", "pro"] })).toString("base64url");
  assert.equal(await verifyEntitlement(publicKey, { ...body.entitlement, payload: forged }), null);

  const keyInfo = await (await call(env, "/api/license/public-key")).json();
  assert.equal(keyInfo.publicKey, publicKey);
  assert.equal(keyInfo.kid, body.entitlement.kid);

  assert.equal((await verify("device-AAAAAAAA")).status, 200); // same device does not use a slot
  assert.equal((await verify("device-BBBBBBBB")).status, 200);
  assert.equal((await verify("device-CCCCCCCC")).status, 409);
  assert.equal((await verify("device-AAAAAAAA", "ROTA-00000-00000-00000-00000")).status, 404);
  assert.equal((await verify("short")).status, 400);
  assert.equal((await verify("device-AAAAAAAA", "nope")).status, 400);

  await deliver(env, {
    id: "evt_cancel",
    type: "customer.subscription.deleted",
    data: { object: { id: "sub_123", status: "canceled" } },
  });
  const cancelled = await verify("device-AAAAAAAA");
  assert.equal(cancelled.status, 403);
  assert.equal((await cancelled.json()).status, "canceled");
});

test("unpaid async checkout does not issue a license until payment succeeds", async () => {
  const { env } = await makeEnv();
  await deliver(env, completed("cs_test_async_000001", { payment_status: "unpaid", mode: "payment", payment_intent: "pi_1" }));
  assert.equal((await call(env, "/api/checkout/session?session_id=cs_test_async_000001")).status, 202);
  await deliver(env, { ...completed("cs_test_async_000001", { mode: "payment", payment_intent: "pi_1" }), id: "evt_async_ok", type: "checkout.session.async_payment_succeeded" });
  assert.equal((await call(env, "/api/checkout/session?session_id=cs_test_async_000001")).status, 200);
  await deliver(env, { id: "evt_refund", type: "charge.refunded", data: { object: { payment_intent: "pi_1", refunded: true } } });
  const row = env.DB.raw.prepare("SELECT status FROM licenses WHERE stripe_payment_intent_id = 'pi_1'").get();
  assert.equal(row.status, "refunded");
});

test("licensing endpoints report not configured without a signing key", async () => {
  const { env } = await makeEnv({ LICENSE_SIGNING_KEY: undefined });
  assert.equal((await call(env, "/api/license/public-key")).status, 503);
  const response = await call(env, "/api/license/verify", {
    method: "POST",
    body: JSON.stringify({ licenseKey: "ROTA-00000-00000-00000-00000", deviceId: "device-AAAAAAAA" }),
  });
  assert.equal(response.status, 503);
});

test("release routes redirect to and serve versioned files", async () => {
  const manifest = {
    version: "1.2.3",
    build: "45",
    url: "https://rota.example/releases/Rota-1.2.3-45.dmg",
    zip: { url: "https://rota.example/releases/Rota-1.2.3-45.zip" },
  };
  const { env } = await makeEnv({
    RELEASES: fakeR2({
      "latest.json": JSON.stringify(manifest),
      "releases/Rota-1.2.3-45.dmg": "dmg-bytes",
      "releases/Rota-1.2.3-45.zip": "zip-bytes",
    }),
  });
  const latest = await call(env, "/download/latest");
  assert.equal(latest.status, 302);
  assert.equal(latest.headers.get("location"), "/releases/Rota-1.2.3-45.dmg");
  assert.equal((await call(env, "/download/latest.zip")).headers.get("location"), "/releases/Rota-1.2.3-45.zip");
  const json = await call(env, "/latest.json");
  assert.equal(json.headers.get("access-control-allow-origin"), "*");
  assert.deepEqual(await json.json(), manifest);
  const file = await call(env, "/releases/Rota-1.2.3-45.dmg");
  assert.equal(file.status, 200);
  assert.equal(file.headers.get("content-type"), "application/x-apple-diskimage");
  assert.equal(file.headers.get("content-length"), "9");
  assert.equal(await file.text(), "dmg-bytes");
  const head = await call(env, "/releases/Rota-1.2.3-45.dmg", { method: "HEAD" });
  assert.equal(head.headers.get("content-length"), "9");
  const partial = await call(env, "/releases/Rota-1.2.3-45.dmg", { headers: { range: "bytes=0-2" } });
  assert.equal(partial.status, 206);
  assert.equal(await partial.text(), "dmg");
  assert.equal((await call(env, "/releases/..%2Fsecret")).status, 404);
  assert.equal((await call(env, "/releases/missing.dmg")).status, 404);
});

test("alias hosts redirect pages to the site but keep serving releases and the API", async () => {
  const manifest = {
    version: "1.2.3",
    build: "45",
    url: "https://rota.example/releases/Rota-1.2.3-45.dmg",
    zip: { url: "https://rota.example/releases/Rota-1.2.3-45.zip", sha256: "ab" },
  };
  const { env } = await makeEnv({
    REDIRECT_HOSTS: "www.rota.example, old.example",
    RELEASES: fakeR2({ "latest.json": JSON.stringify(manifest) }),
  });
  const at = (host, path, init) => worker.fetch(new Request(`https://${host}${path}`, init), env);

  const www = await at("www.rota.example", "/pricing/?ref=x");
  assert.equal(www.status, 301);
  assert.equal(www.headers.get("location"), "https://rota.example/pricing/?ref=x");
  assert.equal((await at("old.example", "/")).headers.get("location"), "https://rota.example/");
  assert.equal((await at("old.example", "/download/")).status, 301, "the download page is a page");

  // Service paths answer on the old host, with download URLs on that same host.
  const old = await at("old.example", "/latest.json");
  assert.equal(old.status, 200);
  const rehosted = await old.json();
  assert.equal(rehosted.url, "https://old.example/releases/Rota-1.2.3-45.dmg");
  assert.equal(rehosted.zip.url, "https://old.example/releases/Rota-1.2.3-45.zip");
  assert.equal(rehosted.zip.sha256, "ab");
  assert.equal((await at("old.example", "/download/latest")).status, 302);
  assert.equal((await at("old.example", "/api/license/public-key")).status, 200);
  assert.equal((await at("old.example", "/latest.json", { method: "HEAD" })).status, 200);

  // The canonical host is never redirected, and an unknown host (preview, local dev) is left alone.
  assert.equal((await at("rota.example", "/pricing/")).status, 404, "falls through to assets (none in tests)");
  assert.equal((await at("localhost:8787", "/pricing/")).status, 404);
  const canonical = await at("rota.example", "/latest.json");
  assert.deepEqual(await canonical.json(), manifest);
});

test("no release yet is a clean 404", async () => {
  const { env } = await makeEnv();
  assert.equal((await call(env, "/download/latest")).status, 404);
  assert.equal((await call(env, "/latest.json")).status, 404);
  assert.equal((await call(env, "/api/unknown")).status, 404);
});
