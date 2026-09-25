import { routeVault, VaultError } from './vault';
import { randomBytes, scrypt, timingSafeEqual, createHash } from 'node:crypto';

const PASSWORD_COST = { N: 16384, r: 8, p: 5, maxmem: 32 * 1024 * 1024 };
const MAX_YAML = 1_048_576;
const SESSION_SECONDS = 30 * 24 * 60 * 60;
class HTTPError extends Error { constructor(readonly status: number, message: string) { super(message); } }
const digest = (value: string) => createHash('sha256').update(value).digest('hex');
const seconds = () => Math.floor(Date.now() / 1000);
function derive(password: string, salt: string): Promise<Buffer> {
  return new Promise((resolve, reject) => scrypt(password, salt, 32, PASSWORD_COST,
    (error, key) => error ? reject(error) : resolve(key)));
}
export async function hashPassword(password: string): Promise<string> {
  const salt = randomBytes(16).toString('hex');
  return `scrypt-v1$${salt}$${(await derive(password, salt)).toString('hex')}`;
}
async function verifyPassword(password: string, stored: string | undefined): Promise<boolean> {
  // Unknown emails still perform the same KDF work; errors never disclose existence.
  const parts = stored?.split('$');
  const valid = parts?.length === 3 && parts[0] === 'scrypt-v1' && /^[a-f0-9]{32}$/.test(parts[1]) && /^[a-f0-9]{64}$/.test(parts[2]);
  const actual = await derive(password, valid ? parts[1] : '00000000000000000000000000000000');
  const expected = Buffer.from(valid ? parts[2] : '0'.repeat(64), 'hex');
  return timingSafeEqual(actual, expected) && !!valid;
}
async function body(request: Request, maximum = 4096): Promise<Record<string, unknown>> {
  if (!request.headers.get('content-type')?.toLowerCase().startsWith('application/json')) throw new HTTPError(415, 'Use application/json.');
  const reader = request.body?.getReader();
  if (!reader) throw new HTTPError(400, 'A JSON body is required.');
  const chunks: Uint8Array[] = [];
  let length = 0;
  while (true) {
    const part = await reader.read();
    if (part.done) break;
    length += part.value.byteLength;
    if (length > maximum) { await reader.cancel(); throw new HTTPError(413, 'Request is too large.'); }
    chunks.push(part.value);
  }
  try {
    const value: unknown = JSON.parse(Buffer.concat(chunks).toString('utf8'));
    if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error();
    return value as Record<string, unknown>;
  } catch { throw new HTTPError(400, 'Invalid JSON.'); }
}
function passwordValue(value: unknown): string {
  if (typeof value !== 'string' || [...value].length < 12 || Buffer.byteLength(value) > 1024) {
    throw new HTTPError(400, 'Use a password of at least 12 characters and at most 1024 bytes.');
  }
  return value; // Never trim, normalize, or truncate a password.
}
function emailValue(value: unknown): string {
  if (typeof value !== 'string') throw new HTTPError(400, 'Enter a valid email address.');
  const email = value.trim().toLowerCase();
  if (email.length > 254 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) throw new HTTPError(400, 'Enter a valid email address.');
  return email;
}
function json(value: unknown, status = 200): Response {
  return Response.json(value, { status, headers: {
    'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff',
    'Strict-Transport-Security': 'max-age=31536000',
    ...(status === 429 ? { 'Retry-After': '60' } : {})
  }});
}
// Global, atomic counters complement the per-location native rate limiter.
async function limit(env: Env, key: string, maximum: number): Promise<void> {
  const now = seconds();
  const result = await env.DB.prepare(`INSERT INTO auth_limits(key,count,expires_at) VALUES (?,1,?)
    ON CONFLICT(key) DO UPDATE SET count=CASE WHEN expires_at<=? THEN 1 ELSE count+1 END,
    expires_at=CASE WHEN expires_at<=? THEN ? ELSE expires_at END RETURNING count`)
    .bind(key, now + 60, now, now, now + 60).first<{ count: number }>();
  if (!result || result.count > maximum) throw new HTTPError(429, 'Too many requests. Try again in a minute.');
}
type User = { id: string; email: string; password_hash: string; auth_version: number };
async function session(request: Request, env: Env): Promise<{ id: string; email: string; tokenHash: string }> {
  const header = request.headers.get('authorization') ?? '';
  if (!/^Bearer [a-f0-9]{64}$/.test(header)) throw new HTTPError(401, 'Please sign in again.');
  const tokenHash = digest(header.slice(7));
  const user = await env.DB.prepare(`SELECT users.id, users.email FROM sessions JOIN users ON users.id=sessions.user_id
    WHERE sessions.token_hash=? AND sessions.expires_at>? AND sessions.auth_version=users.auth_version`).bind(tokenHash, seconds()).first<{ id: string; email: string }>();
  if (!user) throw new HTTPError(401, 'Please sign in again.');
  return { ...user, tokenHash };
}
async function issueSession(env: Env, user: { id: string; email: string; auth_version: number }): Promise<Response> {
  const token = randomBytes(32).toString('hex');
  const expiresAt = seconds() + SESSION_SECONDS;
  await env.DB.prepare('INSERT INTO sessions(token_hash,user_id,expires_at,auth_version) VALUES (?,?,?,?)').bind(digest(token), user.id, expiresAt, user.auth_version).run();
  return json({ token, userID: user.id, email: user.email, expiresAt });
}

async function route(request: Request, env: Env): Promise<Response> {
  const url = new URL(request.url);
  if (url.protocol !== 'https:' && !['localhost','127.0.0.1','[::1]'].includes(url.hostname)) throw new HTTPError(400, 'HTTPS required.');
  const path = url.pathname;
  if (request.method === 'GET' && path === '/health') return json({ service: 'rotagivan-sync', version: 1 });
  // Native-client API: no cookie auth, CORS or browser-origin requests.
  if (request.headers.has('origin')) throw new HTTPError(403, 'Browser requests are not supported.');
  if (url.search) throw new HTTPError(400, 'Query parameters are not supported.');
  const ip = request.headers.get('cf-connecting-ip') ?? 'local';
  if (request.method === 'POST' && ['/v1/register','/v1/login'].includes(path)) {
    if (!(await env.AUTH_LIMITER.limit({ key: digest(ip) })).success) throw new HTTPError(429, 'Too many attempts. Try again in a minute.');
    await limit(env, `ip:${digest(ip)}`, 20);
    const input = await body(request);
    const email = emailValue(input.email), password = passwordValue(input.password);
    await limit(env, `email:${digest(email)}`, 10);
    if (path === '/v1/register') {
      const hash = await hashPassword(password);
      const id = crypto.randomUUID();
      const result = await env.DB.prepare('INSERT INTO users(id,email,password_hash,created_at) VALUES (?,?,?,?) ON CONFLICT(email) DO NOTHING')
        .bind(id, email, hash, seconds()).run();
      if (!result.meta.changes) throw new HTTPError(409, 'Unable to create this account. Try signing in.');
      return issueSession(env, { id, email, auth_version: 0 });
    }
    const user = await env.DB.prepare('SELECT id,email,password_hash,auth_version FROM users WHERE email=?').bind(email).first<User>();
    if (!(await verifyPassword(password, user?.password_hash)) || !user) throw new HTTPError(401, 'Email or password is incorrect.');
    return issueSession(env, user);
  }
  const user = await session(request, env);
  await limit(env, `user:${user.id}`, 120);
  if (path === '/v1/vault' || path.startsWith('/v1/vault/')) return routeVault(request, env, user.id, body);
  if (request.method === 'POST' && path === '/v1/logout') {
    await env.DB.prepare('DELETE FROM sessions WHERE token_hash=?').bind(user.tokenHash).run();
    return json({ ok: true });
  }
  if (request.method === 'POST' && path === '/v1/password') {
    await limit(env, `password:${user.id}`, 5);
    const input = await body(request);
    const current = passwordValue(input.currentPassword), next = passwordValue(input.newPassword);
    const stored = await env.DB.prepare('SELECT password_hash,auth_version FROM users WHERE id=?').bind(user.id).first<{ password_hash: string; auth_version: number }>();
    if (!(await verifyPassword(current, stored?.password_hash)) || !stored) throw new HTTPError(401, 'Current password is incorrect.');
    const hash = await hashPassword(next);
    const changed = await env.DB.batch([
      env.DB.prepare('UPDATE users SET password_hash=?,auth_version=auth_version+1 WHERE id=? AND auth_version=?').bind(hash, user.id, stored.auth_version),
      env.DB.prepare('DELETE FROM sessions WHERE user_id=? AND auth_version<=?').bind(user.id, stored.auth_version)
    ]);
    if (!changed[0].meta.changes) throw new HTTPError(409, 'Password changed on another device. Sign in again.');
    return issueSession(env, { ...user, auth_version: stored.auth_version + 1 });
  }
  if (request.method === 'GET' && path === '/v1/settings') {
    const row = await env.DB.prepare('SELECT yaml,revision,updated_at AS updatedAt FROM settings WHERE user_id=?').bind(user.id).first();
    return json(row ?? { yaml: null, revision: 0, updatedAt: null });
  }
  if (request.method === 'PUT' && path === '/v1/settings') {
    const input = await body(request, MAX_YAML * 2);
    if (Object.keys(input).some(k => !['yaml','baseRevision'].includes(k))) throw new HTTPError(400, 'Unsupported field.');
    if (typeof input.yaml !== 'string' || !input.yaml.trim() || Buffer.byteLength(input.yaml) > MAX_YAML || input.yaml.includes('\0')) throw new HTTPError(400, 'Provide a YAML configuration no larger than 1 MB.');
    if (typeof input.baseRevision !== 'number' || !Number.isSafeInteger(input.baseRevision) || input.baseRevision < 0) throw new HTTPError(400, 'A baseRevision is required.');
    const updatedAt = seconds();
    const result = input.baseRevision === 0
      ? await env.DB.prepare('INSERT INTO settings(user_id,yaml,revision,updated_at) VALUES (?,?,1,?) ON CONFLICT(user_id) DO NOTHING').bind(user.id,input.yaml,updatedAt).run()
      : await env.DB.prepare('UPDATE settings SET yaml=?,revision=revision+1,updated_at=? WHERE user_id=? AND revision=?').bind(input.yaml,updatedAt,user.id,input.baseRevision).run();
    if (!result.meta.changes) throw new HTTPError(409, 'Settings changed on another Mac. Choose which version to keep.');
    return json({ revision: input.baseRevision + 1, updatedAt });
  }
  throw new HTTPError(404, 'Not found.');
}

export default {
  async fetch(request, env): Promise<Response> {
    try { return await route(request, env); }
    catch (error) {
      if (error instanceof HTTPError || error instanceof VaultError) return json({ error: error.message }, error.status);
      // Never log request bodies, emails, credentials, SQL errors or tokens.
      console.error(JSON.stringify({ event: 'request_failed', requestID: crypto.randomUUID() }));
      return json({ error: 'Sync is temporarily unavailable. Local settings are safe.' }, 500);
    }
  },
  async scheduled(_event, env) {
    await env.DB.batch([
      env.DB.prepare('DELETE FROM sessions WHERE expires_at<=?').bind(seconds()),
      env.DB.prepare('DELETE FROM auth_limits WHERE expires_at<=?').bind(seconds())
    ]);
  }
} satisfies ExportedHandler<Env>;
