#!/bin/zsh
set -euo pipefail
script_dir=${0:A:h}
cd "$script_dir/.."
test_dir=$(mktemp -d /tmp/rota-realtime.XXXXXX)
rustc --edition 2021 -O --crate-type cdylib "$script_dir/RustSearch/search.rs" -o "$test_dir/librota_search.dylib"
common=(Rota/Models.swift Rota/AppOverrides.swift Rota/CursorResponse.swift Rota/ScrollResponse.swift Rota/TrackpadDistance.swift Rota/SwipeDirectionClassification.swift Rota/CredentialWorker.swift)
ui_sources=("${common[@]}" Rota/TrackpadReport.swift Rota/EventPoster.swift Rota/MacroPlayback.swift \
  Rota/TemporaryIntention.swift Rota/TemporaryIntentionView.swift \
  Rota/VoiceMicrophoneAdmission.swift Rota/VoiceInputDevice.swift Rota/NoteDictationSession.swift \
  Rota/DoubleTapSwipe.swift Rota/GestureEngine.swift Rota/GestureCalibration.swift \
  Rota/GestureCalibrationView.swift Rota/AppExplorerSelection.swift Rota/SyncCrypto.swift Rota/VoiceActions.swift Rota/VoiceRecognition.swift Rota/OpenAIRealtime.swift Rota/LauncherActions.swift Rota/AppExplorer.swift \
  Rota/UIComponents.swift Rota/HotKeyManager.swift Rota/ShortcutRecorder.swift Rota/AppExplorerSettingsView.swift \
  Rota/ExplorerApplicationCatalog.swift Rota/BrowserBookmarks.swift Rota/ExplorerDestinationPicker.swift \
  Rota/ApplicationIndex.swift Rota/ApplicationIndexObservation.swift \
  Rota/BrowserURLDispatcher.swift \
  Rota/WebsiteFavicon.swift \
  Rota/WindowTiling.swift \
  Rota/ExplorerAppearance.swift \
  Rota/MediaControls.swift \
  Rota/ActionPicker.swift Rota/BindingEditor.swift \
  Rota/HotkeyOrganizer.swift Rota/AppOverridesView.swift \
  Rota/HUDLayerHotkeyEditor.swift \
  Rota/TrackpadInputRouting.swift Rota/AppleTrackpadInput.swift \
  Rota/ExplorerPointerLock.swift \
  Rota/AccessibilitySetup.swift Rota/DeviceDiagnosticsCore.swift Rota/HIDManager.swift)
xcrun swiftc -j 4 -module-cache-path "$test_dir/modules" "${ui_sources[@]}" Rota/Tests/RealtimeLauncherTests.swift -framework AppKit -framework SwiftUI -framework AVFoundation -framework CoreGraphics -framework IOKit -framework Carbon -framework CoreServices -framework Security -o "$test_dir/mock-tests"
"$test_dir/mock-tests" "$test_dir/librota_search.dylib"
if [[ "${1:-}" == "--ui" ]]; then
    bundle="$test_dir/RealtimeTest.app"
    mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
    cp "$test_dir/librota_search.dylib" "$bundle/Contents/Resources/"
    cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>RealtimeTest</string><key>CFBundleIdentifier</key><string>local.rota.realtime-test</string></dict></plist>
PLIST
    xcrun swiftc -j 4 -module-cache-path "$test_dir/modules" "${ui_sources[@]}" Rota/Tests/RealtimeLauncherUISmoke.swift -framework AppKit -framework SwiftUI -framework AVFoundation -framework CoreGraphics -framework IOKit -framework Carbon -framework CoreServices -framework Security -o "$bundle/Contents/MacOS/RealtimeTest"
    "$bundle/Contents/MacOS/RealtimeTest" "$test_dir/realtime.png"
fi
print "Mock tests only: no microphone, credential reads, API requests, or actual action execution. Evidence: $test_dir"
