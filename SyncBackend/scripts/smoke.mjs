// Creates disposable test accounts, tests cross-device sync, then deletes ONLY those accounts.
// Never logs passwords, session tokens, salts, password hashes or settings content.
import assert from 'node:assert/strict';
import { randomBytes, randomUUID } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { parseEnv } from 'node:util';
const base = process.argv[2];
if (base !== 'https://rotagivan-sync.bryan-b4b.workers.dev') throw new Error('Specify the deployed Rotagivan endpoint explicitly.');
const ids = [];
const password = randomBytes(32).toString('hex');
async function call(path, method='GET', data, token) {
  return fetch(`${base}/v1/${path}`, { method, headers:{'Content-Type':'application/json',...(token?{Authorization:`Bearer ${token}`}:{})},
    body:data===undefined?undefined:JSON.stringify(data), redirect:'error' });
}
async function register() {
  const response = await call('register','POST',{email:`rotagivan-test-${randomUUID()}@example.invalid`,password});
  assert.equal(response.status,200,'Registration failed');
  const user = await response.json(); ids.push(user.userID); return user;
}
try {
  const a = await register(), b = await register();
  const yaml = readFileSync('../Rotagivan/DefaultConfiguration.yaml','utf8');
  assert.equal((await call('settings','PUT',{yaml,baseRevision:0},a.token)).status,200);
  const logged = await call('login','POST',{email:a.email,password});
  assert.equal(logged.status,200); const secondMac = await logged.json();
  const remote = await (await call('settings','GET',undefined,secondMac.token)).json();
  assert.equal(remote.yaml,yaml); assert.equal(remote.revision,1);
  assert.equal((await (await call('settings','GET',undefined,b.token)).json()).yaml,null);
  assert.equal((await call('settings','PUT',{yaml,baseRevision:0},secondMac.token)).status,409);
  assert.equal((await call('settings','PUT',{yaml,baseRevision:1},secondMac.token)).status,200);
  assert.equal((await call('settings')).status,401);
  assert.equal((await call('logout','POST',{},secondMac.token)).status,200);
  assert.equal((await call('settings','GET',undefined,secondMac.token)).status,401);
  console.log('Live smoke passed: registration, second-device login, exact YAML sync, per-user isolation, stale-write protection, and logout.');
} finally {
  if (ids.length) {
    const vars = parseEnv(readFileSync(`${homedir()}/.env`,'utf8'));
    const token = vars.CLOUDFLARE_API_TOKEN || vars.CF_API_TOKEN_ACCOUNT || vars.CF_API_TOKEN_USER;
    const account = vars.CLOUDFLARE_ACCOUNT_ID || vars.CF_ACCOUNT_ID;
    const result = await fetch(`https://api.cloudflare.com/client/v4/accounts/${account}/d1/database/ee0c70b0-bb83-484f-aa43-f01b3e568d21/query`,{
      method:'POST',headers:{Authorization:`Bearer ${token}`,'Content-Type':'application/json'},
      body:JSON.stringify({sql:`DELETE FROM users WHERE id IN (${ids.map(()=>'?').join(',')})`,params:ids})
    });
    const outcome = await result.json();
    if (!outcome.success) throw new Error('Test account cleanup failed; remove only test IDs: '+ids.join(', '));
    console.log(`Removed ${ids.length} disposable test accounts and their test sessions/settings.`);
  }
}
