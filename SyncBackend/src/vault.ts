import { createHash } from 'node:crypto';
export class VaultError extends Error { constructor(readonly status: number, message: string) { super(message); } }
type ReadBody = (request: Request, maximum?: number) => Promise<Record<string, unknown>>;
type Vault = { vaultID: string; publicKey: string; ciphertext: string; signature: string; revision: number; updatedAt: number };
type Device = { id: string; publicKey: string; name: string; createdAt: number; grant: string | null };
const now = () => Math.floor(Date.now() / 1000);
const reply = (value: unknown) => Response.json(value, { headers: {
  'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff', 'Strict-Transport-Security': 'max-age=31536000'
}});
function fields(input: Record<string, unknown>, allowed: string[]) {
  if (Object.keys(input).some(key => !allowed.includes(key))) throw new VaultError(400, 'Unsupported vault field.');
}
function encoded(value: unknown, min: number, max = min): string {
  if (typeof value !== 'string' || value.length > max * 2 + 8) throw new VaultError(400, 'Invalid encrypted value.');
  const bytes = Buffer.from(value, 'base64');
  if (bytes.length < min || bytes.length > max || bytes.toString('base64') !== value) throw new VaultError(400, 'Invalid encrypted value.');
  return value;
}
function identifier(value: unknown): string {
  if (typeof value !== 'string' || !/^[a-f0-9-]{36}$/.test(value)) throw new VaultError(400, 'Invalid vault ID.');
  return value;
}
export function vaultMessage(userID: string, vaultID: string, revision: number, ciphertext: string): string {
  return ['rotagivan-vault-v1', 'payload', userID, vaultID, String(revision), ciphertext].join('\n');
}
export function grantMessage(userID: string, vaultID: string, deviceID: string, publicKey: string, ephemeralKey: string, ciphertext: string): string {
  return ['rotagivan-vault-v1', 'grant', userID, vaultID, deviceID, publicKey, ephemeralKey, ciphertext].join('\n');
}
async function verify(publicKey: string, signature: string, message: string) {
  const key = await crypto.subtle.importKey('raw', Buffer.from(publicKey, 'base64'), 'Ed25519', false, ['verify']);
  if (!await crypto.subtle.verify('Ed25519', key, Buffer.from(signature, 'base64'), new TextEncoder().encode(message))) {
    throw new VaultError(403, 'Unlock the vault on a trusted Mac first.');
  }
}
async function readVault(env: Env, userID: string): Promise<Vault | null> {
  return env.DB.prepare('SELECT vault_id AS vaultID,public_key AS publicKey,ciphertext,signature,revision,updated_at AS updatedAt FROM vaults WHERE user_id=?').bind(userID).first<Vault>();
}
export async function routeVault(request: Request, env: Env, userID: string, body: ReadBody): Promise<Response> {
  const path = new URL(request.url).pathname;
  const vault = await readVault(env, userID);
  if (request.method === 'GET' && path === '/v1/vault') {
    const devices = vault ? (await env.DB.prepare('SELECT device_id AS id,public_key AS publicKey,name,created_at AS createdAt,grant_json AS grant FROM vault_devices WHERE user_id=? AND (grant_json IS NOT NULL OR created_at>?) ORDER BY created_at LIMIT 20')
      .bind(userID, now() - 7 * 86400).all<Device>()).results : [];
    return reply({ vault, devices });
  }
  if (request.method === 'PUT' && path === '/v1/vault') {
    const input = await body(request, 24000);
    fields(input, ['vaultID', 'publicKey', 'ciphertext', 'signature', 'baseRevision']);
    const vaultID = identifier(input.vaultID), publicKey = encoded(input.publicKey, 32);
    const ciphertext = encoded(input.ciphertext, 29, 16000), signature = encoded(input.signature, 64);
    const revision = input.baseRevision;
    if (typeof revision !== 'number' || !Number.isSafeInteger(revision) || revision < 0 || revision > 1_000_000_000) throw new VaultError(400, 'Invalid vault revision.');
    if (vault && (vault.vaultID !== vaultID || vault.publicKey !== publicKey)) throw new VaultError(409, 'Vault identity cannot be replaced.');
    if ((!vault && revision !== 0) || (vault && revision !== vault.revision)) throw new VaultError(409, 'Vault changed. Load it before saving.');
    await verify(publicKey, signature, vaultMessage(userID, vaultID, revision + 1, ciphertext));
    const updatedAt = now();
    const result = revision === 0
      ? await env.DB.prepare('INSERT INTO vaults(user_id,vault_id,public_key,ciphertext,signature,revision,updated_at) VALUES (?,?,?,?,?,1,?) ON CONFLICT(user_id) DO NOTHING').bind(userID, vaultID, publicKey, ciphertext, signature, updatedAt).run()
      : await env.DB.prepare('UPDATE vaults SET ciphertext=?,signature=?,revision=revision+1,updated_at=? WHERE user_id=? AND vault_id=? AND public_key=? AND revision=?').bind(ciphertext, signature, updatedAt, userID, vaultID, publicKey, revision).run();
    if (!result.meta.changes) throw new VaultError(409, 'Vault changed. Load it before saving.');
    return reply({ vaultID, publicKey, ciphertext, signature, revision: revision + 1, updatedAt });
  }
  if (!vault) throw new VaultError(404, 'Create a vault on your first Mac.');
  if (request.method === 'POST' && path === '/v1/vault/devices') {
    const input = await body(request);
    fields(input, ['publicKey', 'name']);
    const publicKey = encoded(input.publicKey, 32);
    if (typeof input.name !== 'string' || !input.name.trim() || input.name.length > 128 || /[\u0000-\u001f\u007f]/.test(input.name)) throw new VaultError(400, 'Invalid device name.');
    const id = createHash('sha256').update(Buffer.from(publicKey, 'base64')).digest('hex');
    await env.DB.prepare('DELETE FROM vault_devices WHERE user_id=? AND grant_json IS NULL AND created_at<=?').bind(userID, now() - 7 * 86400).run();
    // Bounded atomic insertion. A registered public key is immutable.
    await env.DB.prepare('INSERT INTO vault_devices(user_id,device_id,public_key,name,created_at) SELECT ?,?,?,?,? WHERE (SELECT COUNT(*) FROM vault_devices WHERE user_id=?)<20 ON CONFLICT(user_id,device_id) DO NOTHING')
      .bind(userID, id, publicKey, input.name, now(), userID).run();
    const device = await env.DB.prepare('SELECT device_id AS id,public_key AS publicKey,name,created_at AS createdAt,grant_json AS grant FROM vault_devices WHERE user_id=? AND device_id=?').bind(userID, id).first<Device>();
    if (!device) throw new VaultError(409, 'Device limit reached.');
    return reply(device);
  }
  if (request.method === 'POST' && path === '/v1/vault/approve') {
    const input = await body(request);
    fields(input, ['deviceID', 'ephemeralKey', 'ciphertext', 'signature']);
    if (typeof input.deviceID !== 'string' || !/^[a-f0-9]{64}$/.test(input.deviceID)) throw new VaultError(400, 'Invalid device.');
    const device = await env.DB.prepare('SELECT device_id AS id,public_key AS publicKey,name,created_at AS createdAt,grant_json AS grant FROM vault_devices WHERE user_id=? AND device_id=?').bind(userID, input.deviceID).first<Device>();
    if (!device || (device.grant === null && device.createdAt <= now() - 7 * 86400)) throw new VaultError(404, 'Request expired. Request access again.');
    const ephemeralKey = encoded(input.ephemeralKey, 32), ciphertext = encoded(input.ciphertext, 60), signature = encoded(input.signature, 64);
    await verify(vault.publicKey, signature, grantMessage(userID, vault.vaultID, device.id, device.publicKey, ephemeralKey, ciphertext));
    const grant = JSON.stringify({ ephemeralKey, ciphertext, signature });
    await env.DB.prepare('UPDATE vault_devices SET grant_json=? WHERE user_id=? AND device_id=? AND public_key=? AND grant_json IS NULL AND created_at>?')
      .bind(grant, userID, device.id, device.publicKey, now() - 7 * 86400).run();
    return reply({ ok: true });
  }
  throw new VaultError(404, 'Not found.');
}

