import { env } from 'cloudflare:workers';
import { SELF } from 'cloudflare:test';
import { beforeAll, beforeEach, expect, it } from 'vitest';
import schema from '../migrations/0001_accounts.sql?raw';
import sessionVersions from '../migrations/0002_session_versions.sql?raw';

type Login = { token: string; userID: string; email: string };
const password = 'a test password that is never used elsewhere';
async function call(path: string, method = 'GET', payload?: unknown, token?: string, ip = crypto.randomUUID()) {
  return SELF.fetch(`https://sync.test/v1/${path}`, { method,
    headers: { 'Content-Type': 'application/json', 'CF-Connecting-IP': ip, ...(token ? { Authorization: `Bearer ${token}` } : {}) },
    body: payload === undefined ? undefined : JSON.stringify(payload) });
}
async function register(email = `${crypto.randomUUID()}@example.test`): Promise<Login> {
  const response = await call('register', 'POST', { email, password });
  expect(response.status).toBe(200);
  return response.json<Login>();
}
beforeAll(async () => {
  for (const sql of (schema + sessionVersions).split(';').map(s => s.trim()).filter(Boolean)) await env.DB.prepare(sql).run();
});
beforeEach(async () => {
  await env.DB.batch(['sessions','settings','users','auth_limits'].map(table => env.DB.prepare(`DELETE FROM ${table}`)));
});
it('stores salted hashes, accepts normalized email, and rejects wrong passwords', async () => {
  const a = await register('Person@Example.test');
  const b = await register();
  const hashes = await env.DB.prepare('SELECT password_hash FROM users').all<{password_hash:string}>();
  expect(hashes.results.every(row => /^scrypt-v1\$[a-f0-9]{32}\$[a-f0-9]{64}$/.test(row.password_hash))).toBe(true);
  expect(hashes.results[0].password_hash).not.toBe(hashes.results[1].password_hash);
  const login = await call('login','POST',{email:' PERSON@example.test ',password});
  expect(login.status).toBe(200);
  expect((await login.json<Login>()).userID).toBe(a.userID);
  expect((await call('login','POST',{email:a.email,password:'incorrect password'})).status).toBe(401);
  expect((await call('login','POST',{email:'absent@example.test',password})).status).toBe(401);
  expect((await call('register','POST',{email:a.email,password})).status).toBe(409);
  const sessions = await env.DB.prepare('SELECT token_hash FROM sessions').all<{token_hash:string}>();
  expect(sessions.results.every(row => row.token_hash !== a.token && row.token_hash !== b.token)).toBe(true);
});
it('isolates two accounts and supports login from a second device', async () => {
  const a = await register(), b = await register();
  expect((await call('settings')).status).toBe(401);
  expect((await call('settings','PUT',{yaml:'formatVersion: 1',baseRevision:0},a.token)).status).toBe(200);
  const other = await call('settings','GET',undefined,b.token);
  expect(await other.json()).toMatchObject({yaml:null,revision:0});
  const secondDevice = await (await call('login','POST',{email:a.email,password})).json<Login>();
  const same = await call('settings','GET',undefined,secondDevice.token);
  expect(await same.json()).toMatchObject({yaml:'formatVersion: 1',revision:1});
  expect((await call('settings','PUT',{yaml:'bad',baseRevision:0,userID:a.userID},b.token)).status).toBe(400);
});
it('rejects stale or racing writes without overwriting data', async () => {
  const a = await register();
  const results = await Promise.all(['first','second'].map(yaml=>call('settings','PUT',{yaml,baseRevision:0},a.token)));
  expect(results.map(r=>r.status).sort()).toEqual([200,409]);
  const value = await (await call('settings','GET',undefined,a.token)).json<{yaml:string;revision:number}>();
  expect(value.revision).toBe(1);
  expect((await call('settings','PUT',{yaml:'stale',baseRevision:0},a.token)).status).toBe(409);
  expect((await (await call('settings','GET',undefined,a.token)).json()).yaml).toBe(value.yaml);
  expect((await call('settings','PUT',{yaml:'next',baseRevision:1},a.token)).status).toBe(200);
});
it('revokes sessions at logout and expiry', async () => {
  const a = await register();
  expect((await call('logout','POST',{},a.token)).status).toBe(200);
  expect((await call('settings','GET',undefined,a.token)).status).toBe(401);
  const b = await register();
  await env.DB.prepare('UPDATE sessions SET expires_at=0 WHERE user_id=?').bind(b.userID).run();
  expect((await call('settings','GET',undefined,b.token)).status).toBe(401);
});
it('changes passwords and revokes all old device tokens', async () => {
  const a = await register();
  const newPassword = 'a different long password';
  const changed = await call('password','POST',{currentPassword:password,newPassword},a.token);
  expect(changed.status).toBe(200);
  const next = await changed.json<Login>();
  expect((await call('settings','GET',undefined,a.token)).status).toBe(401);
  expect((await call('settings','GET',undefined,next.token)).status).toBe(200);
  expect((await call('login','POST',{email:a.email,password})).status).toBe(401);
  expect((await call('login','POST',{email:a.email,password:newPassword})).status).toBe(200);
});
it('enforces global email attempt limits across IPs', async () => {
  const email = 'limited@example.test';
  await env.DB.prepare('INSERT INTO auth_limits(key,count,expires_at) VALUES (?,10,?)')
    .bind('email:' + Buffer.from(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(email))).toString('hex'), Math.floor(Date.now()/1000)+60).run();
  expect((await call('login','POST',{email,password})).status).toBe(429);
});
it('rejects a stale auth-version token even if issued after password rotation', async () => {
  const a = await register();
  await env.DB.prepare('UPDATE users SET auth_version=auth_version+1 WHERE id=?').bind(a.userID).run();
  // Model an old-password login finishing after the password-change transaction.
  await env.DB.prepare('UPDATE sessions SET expires_at=? WHERE user_id=?').bind(Math.floor(Date.now()/1000)+3600,a.userID).run();
  expect((await call('settings','GET',undefined,a.token)).status).toBe(401);
});
it('rejects oversized and malformed input, browser origins, and weak passwords', async () => {
  expect((await call('register','POST',{email:'bad',password})).status).toBe(400);
  expect((await call('register','POST',{email:'a@example.test',password:'short'})).status).toBe(400);
  expect((await call('register','POST',{email:'a@example.test',password:'a'.repeat(5000)})).status).toBe(413);
  const browser = await SELF.fetch('https://sync.test/v1/login',{method:'POST',headers:{Origin:'https://evil.test'}});
  expect(browser.status).toBe(403);
  const a = await register();
  expect((await call('settings','PUT',{yaml:'x',baseRevision:-1},a.token)).status).toBe(400);
  expect((await call('settings','PUT',{yaml:'x'.repeat(1_048_577),baseRevision:0},a.token)).status).toBe(400);
});
