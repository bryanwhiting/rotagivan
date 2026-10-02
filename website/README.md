# Rotagivan website

Astro static marketing site for Cloudflare Workers Static Assets. Includes the sales page, a browser-only HUD simulation, pricing status, customer setup information, and a custom 404 page.

## Local preview

```sh
cd website
npm ci
npm run dev
```

Open http://127.0.0.1:4321. Use Node 22.19+ (a Wrangler transitive dependency requires it). The site also built and passed a deployment dry-run on the initial development Mac's Node 22.16, with that engine warning.

```sh
npm run check
npm run build
npm run deploy:check
```

The HUD has eight commands, scoped keyboard shortcuts (1–8 and Escape), reset, and a four-step workflow tour. Manual selection, stopping, and switching away from the tab cancel the tour. No microphone, native app control, account, payment, or data collection is implemented. Motion respects `prefers-reduced-motion`.

## Cloudflare deployment

This is a separate Worker named `rotagivan-website`; it does not change `rotagivan-sync` or its database. Only `dist/` is uploaded. No Astro adapter or server is needed.

Authenticate with `npx wrangler login`, then run:

```sh
npm run deploy
```

The deploy wrapper uses an existing Wrangler OAuth login, or Cloudflare credentials from the process environment / the existing `~/.env` account convention. It reads only the relevant Cloudflare values and never sources shell commands or prints credentials. Never commit credentials.

For Cloudflare Git builds: root directory `website`, build command `npm run build`, deploy command `npx wrangler deploy`. Set `SITE_URL` to the final HTTPS origin before the production build to enable canonical URLs. A custom domain can be attached to this Worker after domain selection; no domain is assumed in source.

## Launch decisions still needed

- Actual pricing, purchase terms, payment provider, and licensing model. The current pricing page deliberately says **Pricing coming soon**.
- A Developer ID-signed, notarized and stapled customer build. The website does not offer the locally signed development app for public download.
- Verified supported macOS versions, hardware, and processor architectures.
- A production domain, support contact, and privacy/terms documents appropriate to the final app and sale.

Customer distribution is described in `../docs/customer-distribution.md`. Page copy is grounded in the existing app; experimental Apple trackpad support and optional cloud voice requirements are disclosed. The sample Focus macro uses customer-selected apps/shortcuts rather than claiming a built-in universal focus command.

## Verification

Initial browser QA covered all eight commands, keyboard selection, reset, tour completion and cancellation, the pricing FAQ, and setup-page navigation. Home, pricing, and setup were checked at mobile width with no document overflow, plus desktop visual review. `astro check`, production build, and Wrangler's dry-run are the release checks for this static site. Cloudflare authentication/deployment must be verified separately; a dry-run is not a deployment.
