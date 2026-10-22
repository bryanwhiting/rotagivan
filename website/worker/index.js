// rotagivan-website Worker: static Astro assets plus release downloads and
// the Voice mode payment/licensing API. Every request reaches this code
// (wrangler.jsonc `assets.run_worker_first`); anything not handled here is
// served from the Astro build.
//
// Hosts: SITE_URL (rotahud.com) is canonical. The hosts in REDIRECT_HOSTS
// (www, and rota.silvermine.dev which shipped in the app before the domain
// existed) keep serving the release and API paths that installed apps and
// Stripe call, and send every page to the canonical host.
import { HttpError, error } from "./http.js";
import { handleLatestDownload, handleLatestJSON, handleReleaseFile } from "./releases.js";
import {
  handleCheckout,
  handleCheckoutSession,
  handleLicenseVerify,
  handlePublicKey,
  handleWebhook,
} from "./payments.js";

/** Paths that must work on every host: the app and Stripe use them by absolute URL. */
export function isServicePath(pathname) {
  return (
    pathname === "/latest.json" ||
    pathname === "/download/latest" ||
    pathname === "/download/latest.zip" ||
    pathname.startsWith("/releases/") ||
    pathname.startsWith("/api/")
  );
}

/** A 301 to the canonical site for page requests on an alias host, else null. */
export function hostRedirect(request, env) {
  const url = new URL(request.url);
  const aliases = (env.REDIRECT_HOSTS ?? "").split(",").map((h) => h.trim().toLowerCase()).filter(Boolean);
  if (!env.SITE_URL || !aliases.includes(url.host.toLowerCase()) || isServicePath(url.pathname)) return null;
  const target = new URL(url.pathname + url.search, env.SITE_URL);
  if (target.host === url.host) return null;
  return new Response(null, {
    status: 301,
    headers: { location: target.toString(), "cache-control": "public, max-age=3600" },
  });
}

export async function route(request, env) {
  const { pathname } = new URL(request.url);
  const method = request.method;
  const read = method === "GET" || method === "HEAD";

  const redirect = hostRedirect(request, env);
  if (redirect) return redirect;

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
