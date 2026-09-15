#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
build_dir="$script_dir/build"
app_dir="$build_dir/Rotagivan.app"

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
  "$script_dir/TrackpadReport.swift" \
  "$script_dir/EventPoster.swift" \
  "$script_dir/GestureEngine.swift" \
  "$script_dir/HIDManager.swift" \
  "$script_dir/HotKeyManager.swift" \
  "$script_dir/ContentView.swift" \
  "$script_dir/RotagivanApp.swift" \
  -o "$app_dir/Contents/MacOS/Rotagivan"
codesign --force --sign - "$app_dir"
echo "$app_dir"
