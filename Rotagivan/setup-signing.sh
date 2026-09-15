#!/bin/zsh
set -euo pipefail
umask 077

# Run only after the user approves creating a local code-signing identity.
# Never regenerate an established identity: doing so breaks existing TCC grants.
script_dir=${0:A:h}
signing_dir="$script_dir/.signing"
if [[ -f "$signing_dir/certificate.pem" ]]; then
  echo "Signing certificate already exists. Reuse it; do not regenerate it."
  exit 0
fi
keychain=$(security default-keychain -d user | tr -d '"' | xargs)
[[ -f "$keychain" ]] || { echo "Cannot locate the login keychain." >&2; exit 1; }
if security find-certificate -c 'Rotagivan Development' "$keychain" >/dev/null 2>&1; then
  mkdir -p "$signing_dir"
  security find-certificate -c 'Rotagivan Development' -p "$keychain" > "$signing_dir/certificate.pem"
  echo "Reused existing Rotagivan Development certificate."
  exit 0
fi
signing_tmp=$(mktemp -d -t rotagivan-signing)
trap 'rm -f "$signing_tmp/key.pem" "$signing_tmp/import-key.pem" "$signing_tmp/certificate.pem"; rmdir "$signing_tmp"' EXIT
openssl req -new -newkey rsa:3072 -nodes -x509 -sha256 -days 3650 \
  -config "$script_dir/signing.cnf" \
  -keyout "$signing_tmp/key.pem" -out "$signing_tmp/certificate.pem"
# Only codesign is preauthorized to use this key; never use security import -A.
openssl rsa -in "$signing_tmp/key.pem" -out "$signing_tmp/import-key.pem"
security import "$signing_tmp/import-key.pem" -k "$keychain" -t priv -f openssl -x -T /usr/bin/codesign
security add-trusted-cert -r trustRoot -p codeSign -k "$keychain" "$signing_tmp/certificate.pem"
mkdir -p "$signing_dir"
cp "$signing_tmp/certificate.pem" "$signing_dir/certificate.pem"
echo "Local signing identity created. Private key is in Keychain, not the repository."
