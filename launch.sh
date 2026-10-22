#!/bin/zsh
# Install the existing signed build; this script does not build or re-sign it.
set -euo pipefail

repo_dir=${0:A:h}
built_app="$repo_dir/Rota/build/Rota.app"
installed_app=/Applications/Rota.app
certificate="$repo_dir/Rota/.signing/certificate.pem"
process_pattern='(^|/)Rota[.]app/Contents/MacOS/Rota([[:space:]]|$)'
# The app was installed as Rotagivan (bundle id local.rotagivan) before the rename.
legacy_app=/Applications/Rotagivan.app
legacy_process_pattern='(^|/)Rotagivan[.]app/Contents/MacOS/Rotagivan([[:space:]]|$)'

fail() { print -u2 -- "$*"; exit 1; }

# quit_app <name> <bundle id> <process pattern>: ask nicely, then signal.
quit_app() {
  local name=$1 bundle_id=$2 pattern=$3 attempt
  /usr/bin/pgrep -f "$pattern" >/dev/null || return 0
  print -- "Quitting $name and waiting for settings to save…"
  /usr/bin/osascript -e "tell application id \"$bundle_id\" to quit" 2>/dev/null || true
  for attempt in {1..80}; do
    if ! /usr/bin/pgrep -f "$pattern" >/dev/null; then break; fi
    /bin/sleep 0.25
  done
  if /usr/bin/pgrep -f "$pattern" >/dev/null; then
    # A modal dialog or a stalled quit leaves the Apple Event unhandled.
    # Settings are saved as they change, so a signal loses nothing.
    print -- "$name did not answer the quit request; stopping it directly…"
    /usr/bin/pkill -TERM -f "$pattern" || true
    for attempt in {1..20}; do
      if ! /usr/bin/pgrep -f "$pattern" >/dev/null; then break; fi
      /bin/sleep 0.25
    done
    if /usr/bin/pgrep -f "$pattern" >/dev/null; then
      /usr/bin/pkill -KILL -f "$pattern" || true
      /bin/sleep 0.5
    fi
  fi
  if /usr/bin/pgrep -f "$pattern" >/dev/null; then
    fail "$name is still running. Quit all copies, then retry. Nothing was installed."
  fi
}

check_only=false
reset_accessibility=true
for argument in "$@"; do
  case "$argument" in
    --check) check_only=true ;;
    --reset-accessibility) reset_accessibility=true ;;
    --keep-accessibility) reset_accessibility=false ;;
    --help)
      print -- "Usage: $0 [--check] [--keep-accessibility | --reset-accessibility]"
      print -- "Quit Rota, install the signed build, reset its Accessibility permission, and reopen it."
      print -- "--check validates without quitting, copying, resetting permissions, or launching."
      print -- "Accessibility is reset for local.rota by default; --reset-accessibility is also accepted."
      print -- "--keep-accessibility skips the reset when your existing permission is working."
      print -- "You must grant access again in System Settings. Other permissions and settings are unchanged."
      print -- "An installed /Applications/Rotagivan.app (the app's former name) is quit and removed; its"
      print -- "Accessibility and Input Monitoring grants do not carry over, so grant them to Rota once."
      exit 0 ;;
    *) fail "Usage: $0 [--check] [--keep-accessibility | --reset-accessibility] [--help]" ;;
  esac
done

if [[ "$reset_accessibility" == true && "$check_only" == false && $EUID -eq 0 ]]; then
  fail "Run launch.sh as your logged-in user, without sudo, so it resets that user's permission."
fi

[[ -x "$built_app/Contents/MacOS/Rota" ]] || fail "No built app found. Run: zsh \"$repo_dir/Rota/build.sh\""
[[ -f "$certificate" ]] || fail "The saved signing certificate is missing. Restore the existing identity before installing."
[[ ! -L "$installed_app" ]] || fail "$installed_app is a symbolic link; refusing to overwrite its target."
[[ ! -e "$installed_app" || -d "$installed_app" ]] || fail "$installed_app is not an app directory."
[[ ! -L "$legacy_app" ]] || fail "$legacy_app is a symbolic link; refusing to remove its target."
[[ ! -e "$legacy_app" || -d "$legacy_app" ]] || fail "$legacy_app is not an app directory."
[[ -w /Applications ]] || fail "/Applications is not writable. Install the built app using Finder."
legacy_installed=false
[[ -d "$legacy_app" ]] && legacy_installed=true

signing_identity=$(/usr/bin/openssl x509 -in "$certificate" -noout -fingerprint -sha1 | /usr/bin/sed 's/.*=//; s/://g')
[[ "$signing_identity" =~ '^[0-9A-Fa-f]{40}$' ]] || fail "Invalid saved signing certificate."
requirement="=identifier \"local.rota\" and certificate leaf = H\"$signing_identity\""
/usr/bin/codesign --verify --deep --strict -R "$requirement" "$built_app"
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$built_app/Contents/Info.plist")
build=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$built_app/Contents/Info.plist")

if [[ "$check_only" == true ]]; then
  print -- "Ready to install Rota $version (build $build). No changes made."
  if [[ "$reset_accessibility" == true ]]; then
    print -- "A real launch would also reset Accessibility for local.rota. No permissions were reset."
  fi
  if [[ "$legacy_installed" == true ]]; then
    print -- "A real launch would also quit and remove $legacy_app; Rota then needs new Accessibility and Input Monitoring grants."
  fi
  exit 0
fi

quit_app Rota local.rota "$process_pattern"
if [[ "$legacy_installed" == true ]]; then
  quit_app Rotagivan local.rotagivan "$legacy_process_pattern"
  print -- "Removing $legacy_app (the app's former name). Its settings carry over to Rota on first launch."
  /bin/rm -rf "$legacy_app"
fi

print -- "Installing Rota $version (build $build)…"
# Replace, never merge: ditto into an existing bundle keeps stale files and breaks the seal.
/bin/rm -rf "$installed_app"
/usr/bin/ditto "$built_app" "$installed_app"
/usr/bin/codesign --verify --deep --strict -R "$requirement" "$installed_app"
if [[ "$reset_accessibility" == true ]]; then
  print -- "Resetting only Rota's Accessibility permission for the current user…"
  # Never use `reset All`, omit the bundle ID, edit TCC.db, or run with sudo.
  # This revokes permission; it cannot grant access or override management policy.
  if ! /usr/bin/tccutil reset Accessibility local.rota; then
    fail "The app was installed, but macOS refused the Accessibility reset. No broader reset was attempted. Reopen Rota manually; on a managed Mac, contact your administrator."
  fi
fi
/usr/bin/open "$installed_app"
if [[ "$legacy_installed" == true ]]; then
  # macOS keys these grants by bundle identifier; Rotagivan's do not apply to local.rota.
  print -- "Rota replaced Rotagivan and has a new bundle identifier, so macOS treats it as a new app:"
  print -- "grant Accessibility (and Input Monitoring, if asked) to /Applications/Rota.app once more."
  print -- "This is needed even with --keep-accessibility; later installs keep the grant as before."
fi
if [[ "$reset_accessibility" == true || "$legacy_installed" == true ]]; then
  /usr/bin/open 'x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility'
  print -- "Enable /Applications/Rota.app in Accessibility. If missing, use + to add that exact copy."
  print -- "If System Settings shows a stale list, close and reopen it. Then reconnect or relaunch Rota."
fi
print -- "Launched $installed_app — $version (build $build)."
