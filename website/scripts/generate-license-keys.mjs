// Generates the Ed25519 key pair used to sign Voice mode entitlements.
//   node scripts/generate-license-keys.mjs
// Pipe the private key straight into Wrangler so it never lands on disk:
//   node scripts/generate-license-keys.mjs --private-only | npx wrangler secret put LICENSE_SIGNING_KEY
// The public key (raw 32 bytes, base64) is embedded in the Mac app.
import { webcrypto as crypto } from "node:crypto";

const pair = await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"]);
const pkcs8 = Buffer.from(await crypto.subtle.exportKey("pkcs8", pair.privateKey)).toString("base64");
const raw = Buffer.from(await crypto.subtle.exportKey("raw", pair.publicKey));
const kid = Buffer.from(await crypto.subtle.digest("SHA-256", raw)).subarray(0, 8).toString("base64url");

if (process.argv.includes("--private-only")) {
  process.stdout.write(pkcs8);
  console.error(`Public key (embed in the app): ${raw.toString("base64")}  kid=${kid}`);
} else {
  console.log(`LICENSE_SIGNING_KEY (secret; set with wrangler secret put):\n${pkcs8}\n`);
  console.log(`Public key (embed in the app):\n${raw.toString("base64")}\n\nkid: ${kid}`);
}
