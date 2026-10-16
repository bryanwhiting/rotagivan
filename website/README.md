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

The Worker `rotagivan-website` (`worker/index.js`) serves `dist/` as static
assets at https://rota.silvermine.dev (Workers custom domain). Only the paths
in `assets.run_worker_first` run Worker code: release downloads from the
`rotagivan-releases` R2 bucket (`/download/latest`, `/latest.json`,
`/releases/*`), and the Voice mode payments API under `/api/*`, backed by the
`rotagivan-licenses` D1 database. The Worker does not touch `rotagivan-sync`.

```sh
npm test            # Worker tests (node:test; in-memory D1/R2)
npm run deploy      # astro build + wrangler deploy
npm run db:migrate  # apply migrations/ to the remote D1 database
```

`scripts/cloudflare.mjs` runs Wrangler with an existing OAuth login or with
Cloudflare credentials from the environment or `~/.env`, and never prints
them. Publish app builds with `../scripts/release.sh`. For payments setup and
the app licensing contract, see `../docs/payments.md`. For signing,
notarization and the Gatekeeper status, see `../docs/customer-distribution.md`.

## Still to decide before launch

- The Voice mode price (`src/pricing.ts` plus the Stripe price) and the Stripe setup in `docs/payments.md`.
- A Developer ID-signed, notarized build. Until then, the first launch needs Open Anyway.
- Verified macOS versions and architectures. Releases currently contain whatever `build.sh` produced on this Mac (arm64).
- Support contact, terms and privacy pages.

## Verification

Initial browser QA covered all eight commands, keyboard selection, reset, tour completion and cancellation, the pricing FAQ, and setup-page navigation. Home, pricing, and setup were checked at mobile width with no document overflow, plus desktop visual review. `astro check`, production build, and Wrangler's dry-run are the release checks for this static site. Cloudflare authentication/deployment must be verified separately; a dry-run is not a deployment.
