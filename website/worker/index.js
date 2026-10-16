// rotagivan-website Worker: static Astro assets plus release downloads and
// the Voice mode payment/licensing API. Only the paths listed in
// wrangler.jsonc `assets.run_worker_first` reach this code.
import { HttpError, error } from "./http.js";
import { handleLatestDownload, handleLatestJSON, handleReleaseFile } from "./releases.js";
import {
  handleCheckout,
  handleCheckoutSession,
  handleLicenseVerify,
  handlePublicKey,
  handleWebhook,
} from "./payments.js";

export async function route(request, env) {
  const { pathname } = new URL(request.url);
  const method = request.method;
  const read = method === "GET" || method === "HEAD";

  if (pathname === "/latest.json" && read) return handleLatestJSON(request, env);
  if (pathname === "/download/latest" && read) return handleLatestDownload(request, env, "dmg");
  if (pathname === "/download/latest.zip" && read) return handleLatestDownload(request, env, "zip");
  if (pathname.startsWith("/releases/") && read) {
    return handleReleaseFile(request, env, decodeURIComponent(pathname.slice("/releases/".length)));
  }

  if (pathname === "/api/checkout" && method === "POST") return handleCheckout(request, env);
  if (pathname === "/api/checkout/session" && method === "GET") return handleCheckoutSession(request, env);
  if (pathname === "/api/stripe/webhook" && method === "POST") return handleWebhook(request, env);
  if (pathname === "/api/license/verify" && method === "POST") return handleLicenseVerify(request, env);
  if (pathname === "/api/license/public-key" && method === "GET") return handlePublicKey(env);

  if (pathname.startsWith("/api/")) return error(404, "not_found", "Unknown API route.");
  return env.ASSETS ? env.ASSETS.fetch(request) : error(404, "not_found", "Not found.");
}

export default {
  async fetch(request, env) {
    try {
      return await route(request, env);
    } catch (err) {
      if (err instanceof HttpError) return error(err.status, err.code, err.message);
      console.error("unhandled", err?.stack ?? err);
      return error(500, "internal_error", "Something went wrong.");
    }
  },
};
