#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
build_dir="$script_dir/build"
app_dir="$build_dir/Rotagivan.app"
certificate="$script_dir/.signing/certificate.pem"
[[ -f "$certificate" ]] || { echo "Stable signing is required. Run setup-signing.sh after approving local signing setup." >&2; exit 1; }
signing_identity=$(openssl x509 -in "$certificate" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g')
[[ "$signing_identity" =~ '^[0-9A-Fa-f]{40}$' ]] || { echo "Invalid signing certificate fingerprint." >&2; exit 1; }
security find-identity -v -p codesigning | grep -Fq "$signing_identity" || {
  echo "The saved signing identity is unavailable or untrusted. Restore it in Keychain; do not fall back to ad-hoc signing." >&2
  exit 1
}

mkdir -p "$app_dir/Contents/MacOS"
mkdir -p "$app_dir/Contents/Resources"
xcrun swift "$script_dir/DrawIcon.swift" "$build_dir/Rotagivan.iconset"
iconutil -c icns "$build_dir/Rotagivan.iconset" -o "$app_dir/Contents/Resources/Rotagivan.icns"
cp "$script_dir/Info.plist" "$app_dir/Contents/Info.plist"
xcrun swiftc -O -parse-as-library \
  -framework AppKit \
  -framework SwiftUI \
  -framework Carbon \
  -framework IOKit \
  -framework ServiceManagement \
  "$script_dir/Models.swift" \
  "$script_dir/CursorResponse.swift" \
  "$script_dir/MotionCurveEditor.swift" \
  "$script_dir/TrackpadReport.swift" \
  "$script_dir/EventPoster.swift" \
  "$script_dir/GestureEngine.swift" \
  "$script_dir/HIDManager.swift" \
  "$script_dir/HotKeyManager.swift" \
  "$script_dir/ContentView.swift" \
  "$script_dir/ShortcutRecorder.swift" \
  "$script_dir/RotagivanApp.swift" \
  -o "$app_dir/Contents/MacOS/Rotagivan"
codesign --force --sign "$signing_identity" \
  --requirements "=designated => identifier \"local.rotagivan\" and certificate leaf = H\"$signing_identity\"" "$app_dir"
codesign --verify --deep --strict "$app_dir"
codesign -dr - "$app_dir"
echo "$app_dir"
