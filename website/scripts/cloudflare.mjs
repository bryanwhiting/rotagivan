// Use existing environment or the account convention already used by SyncBackend.
// Parse only Cloudflare values: do not source shell commands or log credentials.
import { readFileSync, existsSync } from "node:fs";
import { homedir } from "node:os";
import { parseEnv } from "node:util";
import { spawnSync } from "node:child_process";
const path = `${homedir()}/.env`;
const saved = existsSync(path) ? parseEnv(readFileSync(path, "utf8")) : {};
const env = { ...process.env, WRANGLER_SEND_METRICS: "false" };
const token =
  env.CLOUDFLARE_API_TOKEN ||
  saved.CLOUDFLARE_API_TOKEN ||
  saved.CF_API_TOKEN_ACCOUNT ||
  saved.CF_API_TOKEN_USER;
const account =
  env.CLOUDFLARE_ACCOUNT_ID ||
  saved.CLOUDFLARE_ACCOUNT_ID ||
  saved.CF_ACCOUNT_ID;
if (token) env.CLOUDFLARE_API_TOKEN = token;
if (account) env.CLOUDFLARE_ACCOUNT_ID = account;
// With no token Wrangler can use the user's existing OAuth login.
const result = spawnSync(
  "./node_modules/.bin/wrangler",
  process.argv.slice(2),
  { stdio: "inherit", env },
);
process.exit(result.status ?? 1);
