#!/bin/zsh
set -euo pipefail
script_dir=${0:A:h}
cd "$script_dir/.."
test_dir=$(mktemp -d /tmp/rotagivan-realtime.XXXXXX)
rustc --edition 2021 -O --crate-type cdylib "$script_dir/RustSearch/search.rs" -o "$test_dir/librota_search.dylib"
common=(Rotagivan/Models.swift Rotagivan/AppOverrides.swift Rotagivan/CursorResponse.swift Rotagivan/ScrollResponse.swift Rotagivan/TrackpadDistance.swift Rotagivan/SwipeDirectionClassification.swift Rotagivan/CredentialWorker.swift)
ui_sources=("${common[@]}" Rotagivan/TrackpadReport.swift Rotagivan/EventPoster.swift Rotagivan/MacroPlayback.swift \
  Rotagivan/TemporaryIntention.swift Rotagivan/TemporaryIntentionView.swift \
  Rotagivan/VoiceMicrophoneAdmission.swift Rotagivan/NoteDictationSession.swift \
  Rotagivan/DoubleTapSwipe.swift Rotagivan/GestureEngine.swift Rotagivan/GestureCalibration.swift \
  Rotagivan/GestureCalibrationView.swift Rotagivan/AppExplorerSelection.swift Rotagivan/VaultCrypto.swift Rotagivan/CredentialVault.swift Rotagivan/CredentialVaultView.swift Rotagivan/VoiceActions.swift Rotagivan/VoiceRecognition.swift Rotagivan/OpenAIRealtime.swift Rotagivan/LauncherActions.swift Rotagivan/AppExplorer.swift \
  Rotagivan/HotKeyManager.swift Rotagivan/ShortcutRecorder.swift Rotagivan/AppExplorerSettingsView.swift \
  Rotagivan/ExplorerApplicationCatalog.swift Rotagivan/BrowserBookmarks.swift Rotagivan/ExplorerDestinationPicker.swift \
  Rotagivan/ApplicationIndex.swift Rotagivan/ApplicationIndexObservation.swift \
  Rotagivan/BrowserURLDispatcher.swift \
  Rotagivan/WebsiteFavicon.swift \
  Rotagivan/WindowTiling.swift \
  Rotagivan/ExplorerAppearance.swift \
  Rotagivan/MediaControls.swift \
  Rotagivan/ActionPicker.swift Rotagivan/BindingEditor.swift \
  Rotagivan/HotkeyOrganizer.swift Rotagivan/AppOverridesView.swift \
  Rotagivan/HUDLayerHotkeyEditor.swift \
  Rotagivan/TrackpadInputRouting.swift Rotagivan/AppleTrackpadInput.swift \
  Rotagivan/ExplorerPointerLock.swift \
  Rotagivan/AccessibilitySetup.swift Rotagivan/HIDManager.swift)
xcrun swiftc -j 4 -module-cache-path "$test_dir/modules" "${ui_sources[@]}" Rotagivan/Tests/RealtimeLauncherTests.swift -framework AppKit -framework SwiftUI -framework AVFoundation -framework CoreGraphics -framework IOKit -framework Carbon -framework CoreServices -framework Security -o "$test_dir/mock-tests"
"$test_dir/mock-tests" "$test_dir/librota_search.dylib"
if [[ "${1:-}" == "--ui" ]]; then
    bundle="$test_dir/RealtimeTest.app"
    mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
    cp "$test_dir/librota_search.dylib" "$bundle/Contents/Resources/"
    cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>RealtimeTest</string><key>CFBundleIdentifier</key><string>local.rotagivan.realtime-test</string></dict></plist>
PLIST
    xcrun swiftc -j 4 -module-cache-path "$test_dir/modules" "${ui_sources[@]}" Rotagivan/Tests/RealtimeLauncherUISmoke.swift -framework AppKit -framework SwiftUI -framework AVFoundation -framework CoreGraphics -framework IOKit -framework Carbon -framework CoreServices -framework Security -o "$bundle/Contents/MacOS/RealtimeTest"
    "$bundle/Contents/MacOS/RealtimeTest" "$test_dir/realtime.png"
fi
print "Mock tests only: no microphone, credential reads, API requests, or actual action execution. Evidence: $test_dir"
