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
yaml_dir="$script_dir/../YAML"
swift build --package-path "$yaml_dir" -c release --product ConfigurationYAML
yaml_build=$(swift build --package-path "$yaml_dir" -c release --show-bin-path)
install -m 644 "$script_dir/DefaultConfiguration.yaml" "$app_dir/Contents/Resources/DefaultConfiguration.yaml"
install -m 644 "$yaml_dir/.build/checkouts/Yams/LICENSE" "$app_dir/Contents/Resources/Yams-LICENSE.txt"
install -m 644 "$yaml_dir/LibYAML-LICENSE.txt" "$app_dir/Contents/Resources/LibYAML-LICENSE.txt"
xcrun swift "$script_dir/DrawIcon.swift" "$build_dir/Rotagivan.iconset"
iconutil -c icns "$build_dir/Rotagivan.iconset" -o "$app_dir/Contents/Resources/Rotagivan.icns"
cp "$script_dir/Info.plist" "$app_dir/Contents/Info.plist"
xcrun swiftc -O -parse-as-library \
  -I "$yaml_build/Modules" -L "$yaml_build" -lConfigurationYAML \
  -I "$yaml_dir/.build/checkouts/Yams/Sources/CYaml/include" \
  -framework AppKit \
  -framework SwiftUI \
  -framework Carbon \
  -framework IOKit \
  -framework ServiceManagement \
  -framework Security \
  "$script_dir/Models.swift" \
  "$script_dir/AppOverrides.swift" \
  "$script_dir/AppOverridesView.swift" \
  "$script_dir/AppConfiguration.swift" \
  "$script_dir/ConfigurationSettingsView.swift" \
  "$script_dir/SyncStorage.swift" \
  "$script_dir/SettingsSync.swift" \
  "$script_dir/SyncSettingsView.swift" \
  "$script_dir/CursorResponse.swift" \
  "$script_dir/ScrollResponse.swift" \
  "$script_dir/ScrollCurveEditor.swift" \
  "$script_dir/MotionCurveEditor.swift" \
  "$script_dir/TrackpadReport.swift" \
  "$script_dir/TrackpadDistance.swift" \
  "$script_dir/TrackpadDistanceControl.swift" \
  "$script_dir/EventPoster.swift" \
  "$script_dir/AppExplorerSelection.swift" \
  "$script_dir/ExplorerApplicationCatalog.swift" \
  "$script_dir/ExplorerDestinationPicker.swift" \
  "$script_dir/WebsiteFavicon.swift" \
  "$script_dir/WindowTiling.swift" \
  "$script_dir/AppExplorer.swift" \
  "$script_dir/AppExplorerSettingsView.swift" \
  "$script_dir/GestureEngine.swift" \
  "$script_dir/DoubleTapSwipe.swift" \
  "$script_dir/SwipeDirectionClassification.swift" \
  "$script_dir/DoubleTapSwipeEditor.swift" \
  "$script_dir/GestureCalibration.swift" \
  "$script_dir/GestureCalibrationView.swift" \
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
