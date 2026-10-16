-- Voice mode licenses issued from Stripe purchases.
CREATE TABLE IF NOT EXISTS licenses (
  license_key TEXT PRIMARY KEY,
  status TEXT NOT NULL,                 -- active | past_due | canceled | refunded | ...
  entitlements TEXT NOT NULL DEFAULT '["voice"]',
  email TEXT,
  stripe_customer_id TEXT,
  stripe_checkout_session_id TEXT UNIQUE,
  stripe_subscription_id TEXT,
  stripe_payment_intent_id TEXT,
  mode TEXT NOT NULL,                   -- subscription | payment
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS licenses_subscription ON licenses (stripe_subscription_id);
CREATE INDEX IF NOT EXISTS licenses_payment_intent ON licenses (stripe_payment_intent_id);

CREATE TABLE IF NOT EXISTS activations (
  license_key TEXT NOT NULL REFERENCES licenses (license_key),
  device_id TEXT NOT NULL,
  first_seen INTEGER NOT NULL,
  last_seen INTEGER NOT NULL,
  PRIMARY KEY (license_key, device_id)
);

-- Processed Stripe event ids, for idempotent webhook retries.
CREATE TABLE IF NOT EXISTS stripe_events (
  id TEXT PRIMARY KEY,
  type TEXT NOT NULL,
  received_at INTEGER NOT NULL
);
