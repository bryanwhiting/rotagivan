# Voice mode payments and licensing

Voice mode is the paid feature. Everything else in Rotagivan is free. Payments
go through Stripe Checkout; licensing runs in the `rotagivan-website` Worker
(`website/worker/`), which also serves rota.silvermine.dev. It does not use
`SyncBackend`.

```
browser ──POST /api/checkout──▶ Worker ──▶ Stripe Checkout Session
Stripe ──POST /api/stripe/webhook (signed)──▶ Worker ──▶ D1: license issued
success page ──GET /api/checkout/session?session_id=…──▶ license key shown
Mac app ──POST /api/license/verify {licenseKey, deviceId}──▶ Ed25519-signed entitlement
```

## Current state

| Piece | State |
| --- | --- |
| D1 database `rotagivan-licenses` | Created; migration `0001_licenses.sql` applied |
| Worker routes | Deployed. They return `503 payments_not_configured` / `licensing_not_configured` until the secrets below are set |
| Website | "Get Voice mode" buttons call `/api/checkout` and show "Voice mode purchases open soon." while it is unconfigured |
| Price shown on the site | Placeholder in `website/src/pricing.ts` |
| App-side Voice gate | Not built yet (see the contract below) |

## Setup steps

Run Wrangler commands from `website/`. `node scripts/cloudflare.mjs …` runs
Wrangler with the Cloudflare credentials from `~/.env`.

1. **Create the product in Stripe.** Dashboard → Product catalog → Add product
   "Rotagivan Voice mode". Add a price: recurring (for example monthly) or
   one-time. Copy the price id (`price_…`). Do this in test mode first.
2. **Set the price id and mode** in `website/wrangler.jsonc` `vars`:
   - `STRIPE_PRICE_ID_VOICE`: `price_…`
   - `STRIPE_CHECKOUT_MODE`: `"subscription"` for a recurring price, or
     `"payment"` for a one-time price.
   Also update the displayed price in `website/src/pricing.ts`.
3. **Set the Stripe secret key:**
   `node scripts/cloudflare.mjs secret put STRIPE_SECRET_KEY` (paste
   `sk_test_…`, or later `sk_live_…`; a restricted key with Checkout Sessions
   write access is enough).
4. **Create the webhook endpoint.** Stripe → Developers → Webhooks → Add
   endpoint `https://rota.silvermine.dev/api/stripe/webhook` with these events:
   - `checkout.session.completed`
   - `checkout.session.async_payment_succeeded`
   - `customer.subscription.created`, `customer.subscription.updated`,
     `customer.subscription.deleted`
   - `charge.refunded`
   Copy the signing secret (`whsec_…`), then run
   `node scripts/cloudflare.mjs secret put STRIPE_WEBHOOK_SECRET`.
5. **Create the license signing key.** This key signs entitlements, and the
   app embeds its public key. Run:
   ```sh
   node scripts/generate-license-keys.mjs --private-only | node scripts/cloudflare.mjs secret put LICENSE_SIGNING_KEY
   ```
   The private key goes straight into the Worker secret. The public key is
   printed on stderr: save it for the app. You can read it again later from
   `GET https://rota.silvermine.dev/api/license/public-key`. If you rotate
   this key, every app build that embeds the old public key stops accepting
   new entitlements, so ship an app update first.
6. **Deploy:** `npm run deploy`. Then run a test purchase with card
   `4242 4242 4242 4242`. You should land on `/purchase/success/` and see a
   `ROTA-XXXXX-…` key. To check the database:
   `node scripts/cloudflare.mjs d1 execute rotagivan-licenses --remote --command "select license_key,status,email from licenses"`.
7. **Go live:** repeat steps 1–4 in live mode (new price id, `sk_live_…` and a
   live webhook secret). The license signing key does not change.

Optional vars: `LICENSE_MAX_DEVICES` (default 3), `ENTITLEMENT_TTL_DAYS`
(default 7), `STRIPE_API_VERSION` (defaults to the Stripe account's version).

Not included yet, to consider before launch: emailing the license key (today
it appears only on the success page), a Stripe Customer Portal link for
cancelling, a way for customers to free up device slots, rate limiting on
`/api/license/verify` (Cloudflare WAF rate-limiting rule), terms and privacy
pages, and a tax decision (Stripe Tax).

## API

All responses are JSON. Errors look like `{"error": "<code>", "message": "…"}`.

### `POST /api/checkout`
Body `{}` or `{"email": "…"}`. Returns `{"id": "cs_…", "url": "https://checkout.stripe.com/…"}`.
Redirect the browser to `url`. The session has `metadata.product =
"rotagivan-voice"`; the webhook ignores sessions without it, so Payment Links
need that metadata too. Returns 503 `payments_not_configured` while
unconfigured.

### `POST /api/stripe/webhook`
Stripe only. The `Stripe-Signature` header is checked with HMAC-SHA256 over
`t.rawBody` using `STRIPE_WEBHOOK_SECRET`, with a 5-minute tolerance and a
constant-time comparison. Event ids are recorded, so a retried event is a
no-op. A paid `checkout.session.completed` (or
`async_payment_succeeded`) inserts an `active` license with entitlements
`["voice"]`. Subscription updates map `active`/`trialing` to `active` and
other statuses through unchanged. A deleted subscription becomes `canceled`,
and a fully refunded charge becomes `refunded`.

### `GET /api/checkout/session?session_id=cs_…`
Used by the success page. Returns `{"status": "active", "licenseKey": "ROTA-…"}`,
or `202 {"status": "pending"}` until the webhook has arrived.

### `POST /api/license/verify`
Request:
```json
{ "licenseKey": "ROTA-ABCDE-FGHJK-MNPQR-STVWX", "deviceId": "8-128 chars [A-Za-z0-9._-]" }
```
Success (200):
```json
{
  "valid": true,
  "v": 1, "iss": "rota.silvermine.dev", "sub": "ROTA-…", "deviceId": "…",
  "entitlements": ["voice"], "iat": 1760000000, "exp": 1760604800,
  "entitlement": { "payload": "<base64url JSON>", "signature": "<base64url 64 bytes>", "alg": "Ed25519", "kid": "…" }
}
```
The top-level claims are for convenience only. **The app must trust only the
signed `entitlement`.** Failures: 400 `invalid_license_key` / `invalid_device_id`,
404 `license_not_found`, 403 `license_inactive` (with `status`), 409
`device_limit`, 503 `licensing_not_configured`. A new device uses one of
`LICENSE_MAX_DEVICES` slots; a device that is already activated does not use
another.

### `GET /api/license/public-key`
`{"alg": "Ed25519", "kid": "…", "publicKey": "<base64 raw 32 bytes>"}`. Use
it to check which key the app should embed. Do not fetch it at runtime to
decide trust.

## App-side integration contract (for the later Voice gate)

1. **Device id:** generate a random UUID once and store it locally (Keychain or
   `UserDefaults.standard`). Do not sync it.
2. **Activation:** the user pastes a license key. POST it with the device id to
   `/api/license/verify`. Store the returned `entitlement` object and the
   license key locally (Keychain), not in synced settings.
3. **Offline check** (at launch, and before opening Voice mode):
   ```swift
   import CryptoKit
   let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: embeddedPublicKeyBase64)!)
   let payload = base64urlDecode(entitlement.payload)      // exact signed bytes
   let signature = base64urlDecode(entitlement.signature)  // 64 bytes
   guard publicKey.isValidSignature(signature, for: payload) else { deny() }
   let claims = try JSONDecoder().decode(Claims.self, from: payload)
   // Require: claims.v == 1, claims.deviceId == myDeviceId,
   //          claims.entitlements.contains("voice"), now < claims.exp
   ```
   Verify the signature over the decoded payload bytes **before** parsing
   them, and never re-serialize the JSON first. Base64url has no padding, so
   add `=` padding and map `-`→`+`, `_`→`/` before `Data(base64Encoded:)`.
4. **Refresh:** re-verify online about once a day, and whenever fewer than 3
   days remain before `exp`. Network errors keep the stored entitlement until
   it expires (`ENTITLEMENT_TTL_DAYS`, default 7, is the offline grace period).
   403/404 responses clear it.
5. **Gate:** if there is no valid entitlement, show "Unlock Voice mode" with a
   link to `https://rota.silvermine.dev/pricing/` and a field for the license
   key, instead of starting the microphone.

Tests: `cd website && npm test` covers signature verification, checkout
parameters, purchase → license → signed entitlement → cancellation and
refund, device limits, and the release download routes. It uses an in-memory
D1 (node:sqlite) and R2.
