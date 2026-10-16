#!/bin/zsh
set -euo pipefail
script_dir=${0:A:h}
cd "$script_dir/.."
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/rotagivan-typing.XXXXXX")
# Native UI/FSEvents need the logged-in macOS session. No installed app is changed.
rustc --edition 2021 -O --test "$script_dir/RustSearch/search.rs" -o "$test_dir/rust-tests"
"$test_dir/rust-tests" --nocapture
bundle="$test_dir/TypingTest.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
rustc --edition 2021 -O --crate-type cdylib "$script_dir/RustSearch/search.rs" -o "$bundle/Contents/Resources/librota_search.dylib"
cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>TypingTest</string><key>CFBundleIdentifier</key><string>local.rotagivan.typing-test</string></dict></plist>
PLIST
xcrun swiftc -O -module-cache-path "$test_dir/modules" Rotagivan/ExplorerApplicationCatalog.swift Rotagivan/Tests/TypingSearchTests.swift -framework AppKit -o "$test_dir/bridge-tests"
"$test_dir/bridge-tests" "$bundle/Contents/Resources/librota_search.dylib"
common=(Rotagivan/Models.swift Rotagivan/AppOverrides.swift Rotagivan/CursorResponse.swift Rotagivan/ScrollResponse.swift Rotagivan/TrackpadDistance.swift Rotagivan/SwipeDirectionClassification.swift Rotagivan/CredentialWorker.swift)
ui_sources=("${common[@]}" Rotagivan/TrackpadReport.swift Rotagivan/EventPoster.swift Rotagivan/MacroPlayback.swift \
  Rotagivan/TemporaryIntention.swift Rotagivan/TemporaryIntentionView.swift \
  Rotagivan/VoiceMicrophoneAdmission.swift Rotagivan/NoteDictationSession.swift \
  Rotagivan/DoubleTapSwipe.swift Rotagivan/GestureEngine.swift Rotagivan/GestureCalibration.swift \
  Rotagivan/GestureCalibrationView.swift Rotagivan/AppExplorerSelection.swift Rotagivan/VaultCrypto.swift Rotagivan/CredentialVault.swift Rotagivan/CredentialVaultView.swift Rotagivan/VoiceActions.swift Rotagivan/VoiceRecognition.swift Rotagivan/OpenAIRealtime.swift Rotagivan/LauncherActions.swift Rotagivan/AppExplorer.swift \
  Rotagivan/UIComponents.swift Rotagivan/HotKeyManager.swift Rotagivan/ShortcutRecorder.swift Rotagivan/AppExplorerSettingsView.swift \
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
xcrun swiftc -j 4 -module-cache-path "$test_dir/modules" "${ui_sources[@]}" Rotagivan/Tests/TypingLauncherUISmoke.swift -framework AppKit -framework SwiftUI -framework AVFoundation -framework CoreGraphics -framework IOKit -framework Carbon -framework CoreServices -framework Security -o "$bundle/Contents/MacOS/TypingTest"
"$bundle/Contents/MacOS/TypingTest" "$test_dir/search.png"
print "Search screenshot and test binaries: $test_dir"
