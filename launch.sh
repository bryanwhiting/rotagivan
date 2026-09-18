#!/bin/zsh
# Install the existing signed build; this script does not build or re-sign it.
set -euo pipefail

repo_dir=${0:A:h}
built_app="$repo_dir/Rotagivan/build/Rotagivan.app"
installed_app=/Applications/Rotagivan.app
certificate="$repo_dir/Rotagivan/.signing/certificate.pem"
process_pattern='(^|/)Rotagivan[.]app/Contents/MacOS/Rotagivan([[:space:]]|$)'

fail() { print -u2 -- "$*"; exit 1; }

if [[ $# -gt 1 || ( $# -eq 1 && "$1" != --check && "$1" != --help ) ]]; then
  fail "Usage: $0 [--check | --help]"
fi
if [[ ${1:-} == --help ]]; then
  print -- "Usage: $0 [--check]"
  print -- "Quit Rotagivan, install the existing signed build in /Applications, and reopen it."
  print -- "--check validates the build without quitting, copying, or launching."
  exit 0
fi

[[ -x "$built_app/Contents/MacOS/Rotagivan" ]] || fail "No built app found. Run: zsh \"$repo_dir/Rotagivan/build.sh\""
[[ -f "$certificate" ]] || fail "The saved signing certificate is missing. Restore the existing identity before installing."
[[ ! -L "$installed_app" ]] || fail "$installed_app is a symbolic link; refusing to overwrite its target."
[[ ! -e "$installed_app" || -d "$installed_app" ]] || fail "$installed_app is not an app directory."
[[ -w /Applications ]] || fail "/Applications is not writable. Install the built app using Finder."

signing_identity=$(/usr/bin/openssl x509 -in "$certificate" -noout -fingerprint -sha1 | /usr/bin/sed 's/.*=//; s/://g')
[[ "$signing_identity" =~ '^[0-9A-Fa-f]{40}$' ]] || fail "Invalid saved signing certificate."
requirement="=identifier \"local.rotagivan\" and certificate leaf = H\"$signing_identity\""
/usr/bin/codesign --verify --deep --strict -R "$requirement" "$built_app"
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$built_app/Contents/Info.plist")
build=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$built_app/Contents/Info.plist")

if [[ ${1:-} == --check ]]; then
  print -- "Ready to install Rotagivan $version (build $build). No changes made."
  exit 0
fi

if /usr/bin/pgrep -f "$process_pattern" >/dev/null; then
  print -- "Quitting Rotagivan and waiting for settings to save…"
  /usr/bin/osascript -e 'tell application id "local.rotagivan" to quit'
  for attempt in {1..80}; do
    if ! /usr/bin/pgrep -f "$process_pattern" >/dev/null; then break; fi
    /bin/sleep 0.25
  done
  if /usr/bin/pgrep -f "$process_pattern" >/dev/null; then
    fail "Rotagivan is still running. Quit all copies, then retry. Nothing was installed."
  fi
fi

print -- "Installing Rotagivan $version (build $build)…"
/usr/bin/ditto "$built_app" "$installed_app"
/usr/bin/codesign --verify --deep --strict -R "$requirement" "$installed_app"
/usr/bin/open "$installed_app"
print -- "Launched $installed_app — $version (build $build)."
