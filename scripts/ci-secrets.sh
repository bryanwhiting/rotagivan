#!/bin/zsh
# Store what the Release and Website workflows need as GitHub Actions secrets:
#
#   SIGNING_P12, SIGNING_P12_PASSWORD  the "Rotagivan Development" identity, exported
#                                      from the login Keychain (macOS asks once to allow
#                                      exporting the private key: click Allow)
#   SIGNING_CERTIFICATE_PEM            Rota/.signing/certificate.pem
#   CLOUDFLARE_API_TOKEN, CLOUDFLARE_ACCOUNT_ID   from ~/.env (same names SyncBackend uses)
#
# Nothing is printed and nothing is left on disk. Re-run any time to rotate.
# Later, with an Apple Developer ID, export that identity the same way and set
# DEVELOPER_ID / NOTARY_PROFILE in release.yml (see scripts/release.sh).
set -euo pipefail
umask 077

repo=${0:A:h:h}
certificate=$repo/Rota/.signing/certificate.pem
die() { print -u2 -- "ci-secrets: $*"; exit 1; }
step() { print -P -- "%B==> $*%b"; }

command -v gh >/dev/null || die "install the GitHub CLI (brew install gh) and run gh auth login"
gh auth status >/dev/null 2>&1 || die "run gh auth login first"
[[ -f $certificate ]] || die "missing $certificate"
cd "$repo"

keychain=$(security default-keychain -d user | tr -d '"' | xargs)
[[ -f $keychain ]] || die "cannot locate the login keychain"
expected=$(/usr/bin/openssl x509 -in "$certificate" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g')
valid=$(security find-identity -v -p codesigning "$keychain" | grep -c '^ *[0-9]) ' || true)
(( valid == 1 )) || die "expected exactly one code-signing identity in the login keychain, found $valid; export \"Rotagivan Development\" from Keychain Access as a .p12 instead and set the secrets by hand"
security find-identity -v -p codesigning "$keychain" | grep -Fq "$expected" || die "the keychain identity is not the certificate in $certificate"

tmp=$(mktemp -d -t rota-ci-secrets)
trap 'rm -rf "$tmp"' EXIT
password=$(/usr/bin/openssl rand -base64 30)

step "Exporting the signing identity (allow the Keychain prompt)"
security export -k "$keychain" -t identities -f pkcs12 -P "$password" -o "$tmp/identity.p12"
# The archive must contain exactly the pinned certificate and its key.
exported=$(/usr/bin/openssl pkcs12 -in "$tmp/identity.p12" -passin "pass:$password" -nokeys -clcerts 2>/dev/null \
  | /usr/bin/openssl x509 -noout -fingerprint -sha1 | sed 's/.*=//; s/://g')
[[ $exported == "$expected" ]] || die "the exported identity does not match $certificate"
/usr/bin/openssl pkcs12 -in "$tmp/identity.p12" -passin "pass:$password" -nocerts -nodes 2>/dev/null | grep -q 'PRIVATE KEY' \
  || die "the export contains no private key"

step "Setting signing secrets"
base64 -i "$tmp/identity.p12" | gh secret set SIGNING_P12
printf '%s' "$password" | gh secret set SIGNING_P12_PASSWORD
gh secret set SIGNING_CERTIFICATE_PEM < "$certificate"

step "Setting Cloudflare secrets from ~/.env"
# Parse ~/.env without sourcing it; accept the same fallback names as website/scripts/cloudflare.mjs.
python3 -I - "$HOME/.env" "$tmp/cf" <<'PY'
import os, sys
path, out = sys.argv[1], sys.argv[2]
values = {}
if os.path.exists(path):
    for line in open(path, encoding="utf-8"):
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip().removeprefix("export ").strip()
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        values[key] = value
token = os.environ.get("CLOUDFLARE_API_TOKEN") or values.get("CLOUDFLARE_API_TOKEN") or values.get("CF_API_TOKEN_ACCOUNT") or values.get("CF_API_TOKEN_USER")
account = os.environ.get("CLOUDFLARE_ACCOUNT_ID") or values.get("CLOUDFLARE_ACCOUNT_ID") or values.get("CF_ACCOUNT_ID")
if not token or not account:
    sys.exit("ci-secrets: CLOUDFLARE_API_TOKEN / CLOUDFLARE_ACCOUNT_ID (or CF_* equivalents) not found in ~/.env")
os.makedirs(out, mode=0o700)
with open(os.path.join(out, "token"), "w") as f: f.write(token)
with open(os.path.join(out, "account"), "w") as f: f.write(account)
PY
gh secret set CLOUDFLARE_API_TOKEN < "$tmp/cf/token"
gh secret set CLOUDFLARE_ACCOUNT_ID < "$tmp/cf/account"

step "Secrets now set on $(gh repo view --json nameWithOwner -q .nameWithOwner)"
gh secret list
