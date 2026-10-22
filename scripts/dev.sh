#!/bin/zsh
# Run a development build straight from Rota/build, leaving the installed
# /Applications/Rota.app (the released, downloaded copy) alone.
#
#   scripts/dev.sh             build with Rota/build.sh, then run it
#   scripts/dev.sh --no-build  run the existing build
#
# Only one Rota can own the hotkeys and the Navigator, so the installed copy is
# quit first and reopened when the development copy exits (or on Ctrl-C). Both
# copies share the bundle identifier local.rota, so they share settings and the
# Accessibility / Input Monitoring grants (the signing identity is the same).
set -euo pipefail

repo=${0:A:h:h}
built=$repo/Rota/build/Rota.app
installed=/Applications/Rota.app
certificate=$repo/Rota/.signing/certificate.pem
built_pattern="(^|/)${built:t}/Contents/MacOS/Rota([[:space:]]|\$)"
fail() { print -u2 -- "dev: $*"; exit 1; }

build=1
for arg in "$@"; do
  case $arg in
    --no-build) build=0 ;;
    -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
    *) fail "unknown argument: $arg" ;;
  esac
done

(( build )) && zsh "$repo/Rota/build.sh"
[[ -x $built/Contents/MacOS/Rota ]] || fail "no build at $built"
[[ -f $certificate ]] || fail "missing $certificate"
fingerprint=$(/usr/bin/openssl x509 -in "$certificate" -noout -fingerprint -sha1 | /usr/bin/sed 's/.*=//; s/://g')
/usr/bin/codesign --verify --deep --strict -R "=identifier \"local.rota\" and certificate leaf = H\"$fingerprint\"" "$built"
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$built/Contents/Info.plist")
label=$(/usr/libexec/PlistBuddy -c 'Print RotaDisplayVersion' "$built/Contents/Info.plist" 2>/dev/null || echo "$version")

quit_rota() {
  /usr/bin/pgrep -f 'Rota[.]app/Contents/MacOS/Rota' >/dev/null || return 0
  /usr/bin/osascript -e 'tell application id "local.rota" to quit' 2>/dev/null || true
  for _ in {1..80}; do
    /usr/bin/pgrep -f 'Rota[.]app/Contents/MacOS/Rota' >/dev/null || return 0
    /bin/sleep 0.25
  done
  /usr/bin/pkill -TERM -f 'Rota[.]app/Contents/MacOS/Rota' || true
  /bin/sleep 1
}

restore() {
  trap - INT TERM EXIT
  print -- "Stopping the development copy…"
  /usr/bin/pkill -f "$built_pattern" 2>/dev/null || true
  for _ in {1..40}; do
    /usr/bin/pgrep -f "$built_pattern" >/dev/null || break
    /bin/sleep 0.25
  done
  if [[ -d $installed ]]; then
    print -- "Reopening $installed"
    /usr/bin/open "$installed"
  fi
}

print -- "Quitting the installed Rota…"
quit_rota
trap restore INT TERM EXIT
print -- "Running $built ($label). Ctrl-C to stop and reopen the installed copy."
/usr/bin/open -W -n "$built"
