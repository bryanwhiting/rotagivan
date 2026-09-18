#!/bin/zsh
# Install the existing signed build; this script does not build or re-sign it.
set -euo pipefail

repo_dir=${0:A:h}
built_app="$repo_dir/Rotagivan/build/Rotagivan.app"
installed_app=/Applications/Rotagivan.app
certificate="$repo_dir/Rotagivan/.signing/certificate.pem"
process_pattern='(^|/)Rotagivan[.]app/Contents/MacOS/Rotagivan([[:space:]]|$)'

fail() { print -u2 -- "$*"; exit 1; }

check_only=false
reset_accessibility=false
for argument in "$@"; do
  case "$argument" in
    --check) check_only=true ;;
    --reset-accessibility) reset_accessibility=true ;;
    --help)
      print -- "Usage: $0 [--check] [--reset-accessibility]"
      print -- "Quit Rotagivan, install the existing signed build in /Applications, and reopen it."
      print -- "--check validates without quitting, copying, resetting permissions, or launching."
      print -- "--reset-accessibility clears only Rotagivan's Accessibility decision for this user."
      print -- "You must grant access again in System Settings. Other permissions and settings are unchanged."
      exit 0 ;;
    *) fail "Usage: $0 [--check] [--reset-accessibility] [--help]" ;;
  esac
done

if [[ "$reset_accessibility" == true && "$check_only" == false && $EUID -eq 0 ]]; then
  fail "Run --reset-accessibility as your logged-in user, without sudo, so it resets that user's permission."
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

if [[ "$check_only" == true ]]; then
  print -- "Ready to install Rotagivan $version (build $build). No changes made."
  if [[ "$reset_accessibility" == true ]]; then
    print -- "A real launch would also reset Accessibility for local.rotagivan. No permissions were reset."
  fi
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
if [[ "$reset_accessibility" == true ]]; then
  print -- "Resetting only Rotagivan's Accessibility permission for the current user…"
  # Never use `reset All`, omit the bundle ID, edit TCC.db, or run with sudo.
  # This revokes permission; it cannot grant access or override management policy.
  if ! /usr/bin/tccutil reset Accessibility local.rotagivan; then
    fail "The app was installed, but macOS refused the Accessibility reset. No broader reset was attempted. Reopen Rotagivan manually; on a managed Mac, contact your administrator."
  fi
fi
/usr/bin/open "$installed_app"
if [[ "$reset_accessibility" == true ]]; then
  /usr/bin/open 'x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility'
  print -- "Enable /Applications/Rotagivan.app in Accessibility. If missing, use + to add that exact copy."
  print -- "If System Settings shows a stale list, close and reopen it. Then reconnect or relaunch Rotagivan."
fi
print -- "Launched $installed_app — $version (build $build)."
