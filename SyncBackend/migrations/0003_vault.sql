-- Client-encrypted credentials. This database never receives decryption keys.
CREATE TABLE IF NOT EXISTS vaults (
  user_id TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  vault_id TEXT NOT NULL,
  public_key TEXT NOT NULL,
  ciphertext TEXT NOT NULL,
  signature TEXT NOT NULL,
  revision INTEGER NOT NULL CHECK (revision > 0),
  updated_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS vault_devices (
  user_id TEXT NOT NULL REFERENCES vaults(user_id) ON DELETE CASCADE,
  device_id TEXT NOT NULL,
  public_key TEXT NOT NULL,
  name TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  grant_json TEXT,
  PRIMARY KEY(user_id, device_id)
);
