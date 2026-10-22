#!/bin/zsh
set -euo pipefail
script_dir=${0:A:h}
cd "$script_dir/.."
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/rota-typing.XXXXXX")
# Native UI/FSEvents need the logged-in macOS session. No installed app is changed.
rustc --edition 2021 -O --test "$script_dir/RustSearch/search.rs" -o "$test_dir/rust-tests"
"$test_dir/rust-tests" --nocapture
bundle="$test_dir/TypingTest.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
rustc --edition 2021 -O --crate-type cdylib "$script_dir/RustSearch/search.rs" -o "$bundle/Contents/Resources/librota_search.dylib"
cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>TypingTest</string><key>CFBundleIdentifier</key><string>local.rota.typing-test</string></dict></plist>
PLIST
xcrun swiftc -O -module-cache-path "$test_dir/modules" Rota/ExplorerApplicationCatalog.swift Rota/Tests/TypingSearchTests.swift -framework AppKit -o "$test_dir/bridge-tests"
"$test_dir/bridge-tests" "$bundle/Contents/Resources/librota_search.dylib"
common=(Rota/Models.swift Rota/AppOverrides.swift Rota/CursorResponse.swift Rota/ScrollResponse.swift Rota/TrackpadDistance.swift Rota/SwipeDirectionClassification.swift Rota/CredentialWorker.swift)
ui_sources=("${common[@]}" Rota/TrackpadReport.swift Rota/EventPoster.swift Rota/MacroPlayback.swift \
  Rota/TemporaryIntention.swift Rota/TemporaryIntentionView.swift \
  Rota/VoiceMicrophoneAdmission.swift Rota/VoiceInputDevice.swift Rota/NoteDictationSession.swift \
  Rota/DoubleTapSwipe.swift Rota/GestureEngine.swift Rota/GestureCalibration.swift \
  Rota/GestureCalibrationView.swift Rota/AppExplorerSelection.swift Rota/SyncCrypto.swift Rota/VoiceActions.swift Rota/VoiceRecognition.swift Rota/OpenAIRealtime.swift Rota/LauncherActions.swift Rota/AppExplorer.swift \
  Rota/UIComponents.swift Rota/HotKeyManager.swift Rota/ShortcutRecorder.swift Rota/AppExplorerSettingsView.swift \
  Rota/ExplorerApplicationCatalog.swift Rota/BrowserBookmarks.swift Rota/ExplorerDestinationPicker.swift \
  Rota/ApplicationIndex.swift Rota/ApplicationIndexObservation.swift \
  Rota/BrowserURLDispatcher.swift Rota/ChromeHistory.swift \
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
xcrun swiftc -j 4 -module-cache-path "$test_dir/modules" "${ui_sources[@]}" Rota/Tests/TypingLauncherUISmoke.swift -framework AppKit -framework SwiftUI -framework AVFoundation -framework CoreGraphics -framework IOKit -framework Carbon -framework CoreServices -framework Security -o "$bundle/Contents/MacOS/TypingTest"
"$bundle/Contents/MacOS/TypingTest" "$test_dir/search.png"
print "Search screenshot and test binaries: $test_dir"
