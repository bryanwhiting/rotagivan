#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
cd "$script_dir"

for argument in "$@"; do
  case "$argument" in
    --keep-accessibility) ;;
    --help)
      print "Usage: $0 [--keep-accessibility]"
      print "Build, sign, install, and launch Rota without resetting Accessibility."
      exit 0 ;;
    *) print -u2 "Usage: $0 [--keep-accessibility] [--help]"; exit 1 ;;
  esac
done

npm run tauri build -- --bundles app
app_source="$script_dir/src-tauri/target/release/bundle/macos/Rota.app"
app_target="/Applications/Rota.app"
certificate="$script_dir/../Rotagivan/.signing/certificate.pem"

if [[ ! -d "$app_source" ]]; then
  print -u2 "Rota build not found at $app_source"
  exit 1
fi

if [[ ! -f "$certificate" ]]; then
  print -u2 "Saved Rotagivan Development certificate not found at $certificate"
  exit 1
fi

signing_identity=$(/usr/bin/openssl x509 -in "$certificate" -noout -fingerprint -sha1 | /usr/bin/sed 's/.*=//; s/://g')
if [[ ! "$signing_identity" =~ '^[0-9A-Fa-f]{40}$' ]]; then
  print -u2 "Invalid saved signing certificate"
  exit 1
fi
/usr/bin/security find-identity -v -p codesigning | /usr/bin/grep -Fq "$signing_identity" || {
  print -u2 "Rotagivan Development signing identity is unavailable in Keychain"
  exit 1
}
requirement="=identifier \"app.rota.desktop\" and certificate leaf = H\"$signing_identity\""
/usr/bin/codesign --force --deep --sign "$signing_identity" \
  --requirements "=designated => identifier \"app.rota.desktop\" and certificate leaf = H\"$signing_identity\"" "$app_source"
/usr/bin/codesign --verify --deep --strict -R "$requirement" "$app_source"

osascript -e 'tell application "Rota" to quit' >/dev/null 2>&1 || true
for _ in {1..30}; do
  pgrep -x rota >/dev/null || break
  sleep 0.1
done
ditto "$app_source" "$app_target"
/usr/bin/codesign --verify --deep --strict -R "$requirement" "$app_target"
open "$app_target"
print "Installed and launched $app_target"
