# Building, releasing and installing

Two copies of Rota exist on a development Mac and they never mix:

| | Released copy | Development copy |
| --- | --- | --- |
| Where | `/Applications/Rota.app` | `Rota/build/Rota.app` |
| Comes from | a download, or the in-app updater | `zsh Rota/build.sh` |
| Built by | GitHub Actions from a tag | you, from the working tree |
| Run with | Finder / login item | `scripts/dev.sh` |

Both are signed with the same "Rotagivan Development" identity and share the
bundle identifier `local.rota`, so settings, Keychain items and the
Accessibility / Input Monitoring grants are shared. `launch.sh` (copy the local
build into `/Applications`) still works but is no longer the normal path.

## Day to day

```sh
scripts/install-hooks.sh        # once per clone: pre-push gate
zsh Rota/build.sh               # compile + sign into Rota/build/Rota.app
zsh Rota/test.sh                # full suite (needs this Mac, Accessibility granted)
scripts/dev.sh                  # build, quit the installed Rota, run the build; Ctrl-C reopens the installed one
scripts/dev.sh --no-build       # run the existing build
```

The **pre-push hook** (`scripts/githooks/pre-push`) refuses a push whose
commits touch `Rota/` or `YAML/` unless `Rota/build.sh` succeeds, and runs the
website and SyncBackend checks when those directories changed. It does not run
the Swift test suite (that gates the release, below). `ROTA_SKIP_HOOKS=1 git
push` skips it once. The hook runs on push rather than commit because a build
takes minutes and a commit should not.

## Cutting a release

```sh
scripts/tag-release.sh            # 1.1.249 -> 1.1.250, build +1
scripts/tag-release.sh 1.2.0      # explicit version
scripts/tag-release.sh --skip-tests
```

The script requires a clean `main` that is not behind `origin/main`, runs
`zsh Rota/test.sh`, bumps `CFBundleShortVersionString` and `CFBundleVersion` in
`Rota/Info.plist`, commits `Release X.Y.Z (N)`, tags `vX.Y.Z` and pushes both.
Nothing is built locally.

`.github/workflows/release.yml` then runs on a macOS runner:

1. imports the signing identity into a throw-away keychain and trusts the
   certificate for code signing;
2. `zsh Rota/build.sh` (the build-provenance check confirms the checkout is
   clean) and checks the tag equals `v` + the plist version;
3. `scripts/release.sh --skip-build`: packages the DMG and zip, writes
   `latest.json`, uploads to the `rotagivan-releases` R2 bucket, and verifies
   that `https://rota.silvermine.dev/download/latest` serves the new DMG with
   the right checksum;
4. attaches the files to a GitHub release for the tag.

Follow a run with `gh run watch --exit-status` or at
https://github.com/bryanwhiting/rotagivan/actions. "Run workflow" on the
Release workflow packages the current commit without publishing (tick
*publish* to upload); use it to test the pipeline.

`.github/workflows/website.yml` deploys the site whenever `main` changes under
`website/`. SyncBackend stays a manual `npm run deploy` (it owns the database
migrations).

### One-time setup

```sh
scripts/ci-secrets.sh
```

Exports the "Rotagivan Development" identity from the login Keychain as a
password-protected `.p12` (macOS asks once to allow the export) and stores it,
the certificate and the Cloudflare token/account from `~/.env` as repository
secrets with `gh secret set`. Nothing is printed or left on disk. Re-run to
rotate.

The repository is public; secrets are never exposed to pull requests from
forks, and the Release workflow only runs for tags and manual dispatch.

## Installing and updating

- **New Mac**: https://rota.silvermine.dev/download/ (`/download/latest` always
  redirects to the newest DMG). The app is signed with a self-signed
  certificate, so the first launch of a downloaded copy needs *Open Anyway* in
  System Settings → Privacy & Security. Grant Accessibility and Input
  Monitoring once.
- **Updating**: Rota checks `latest.json` daily (and via *Check for Updates…*).
  When the installed copy sits in a writable folder such as `/Applications`,
  the prompt offers **Install and Relaunch**: the app downloads the zip,
  checks its SHA-256 against `latest.json`, confirms the bundle identifier and
  version, verifies the new bundle against the running copy's own designated
  code-signing requirement (same identifier, same certificate), then hands the
  swap to a small shell script and quits. The script waits for the process to
  exit, moves the old bundle aside, copies the new one in (restoring the old
  one if that fails), reopens Rota and deletes its staging folder. Files
  downloaded by the app carry no quarantine attribute, so Gatekeeper never
  sees them, and the identical signature keeps the TCC grants.
  Development builds (`Rota/build`, or anything not identified as
  `local.rota`) never check for updates.

## Later: Apple Developer ID

Nothing above changes except signing. Export the Developer ID identity the same
way (`scripts/ci-secrets.sh` only handles a single identity; export the second
one from Keychain Access and set `SIGNING_P12`/`SIGNING_P12_PASSWORD` by hand or
add a second pair of secrets), then set `DEVELOPER_ID` and `NOTARY_PROFILE` in
the Release workflow's *Package and publish* step; `scripts/release.sh`
re-signs with hardened runtime, notarizes and staples. Because the designated
requirement then names a different certificate, the first Developer ID build
cannot be installed by the in-app updater over a development-signed copy and
needs one manual download plus a fresh Accessibility grant.
