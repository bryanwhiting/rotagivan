// Read only Cloudflare credentials; never source shell code from ~/.env.
import { readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { parseEnv } from 'node:util';
import { spawnSync } from 'node:child_process';
const vars = parseEnv(readFileSync(`${homedir()}/.env`, 'utf8'));
const token = vars.CLOUDFLARE_API_TOKEN || vars.CF_API_TOKEN_ACCOUNT || vars.CF_API_TOKEN_USER;
const account = vars.CLOUDFLARE_ACCOUNT_ID || vars.CF_ACCOUNT_ID;
if (!token || !account) throw new Error('Cloudflare account ID and API token are required in ~/.env');
const result = spawnSync('./node_modules/.bin/wrangler', process.argv.slice(2), {
  stdio: 'inherit', env: { ...process.env, CLOUDFLARE_API_TOKEN: token, CLOUDFLARE_ACCOUNT_ID: account,
    WRANGLER_SEND_METRICS: 'false' }
});
process.exit(result.status ?? 1);
