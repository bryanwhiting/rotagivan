#!/bin/zsh
set -euo pipefail
script_dir=${0:A:h}
cd "$script_dir/.."
test_dir=$(mktemp -d /private/tmp/rotagivan-tests.XXXXXX)
swift build --package-path YAML -c release --product ConfigurationYAML
yaml_build=$(swift build --package-path YAML -c release --show-bin-path)
common=(Rotagivan/Models.swift Rotagivan/AppOverrides.swift Rotagivan/CursorResponse.swift Rotagivan/ScrollResponse.swift Rotagivan/TrackpadDistance.swift Rotagivan/SwipeDirectionClassification.swift Rotagivan/CredentialWorker.swift)
for test in CursorResponseTests CursorGainTests CursorTelemetryTests ScrollResponseTests ConfigurationProfileTests PointerProfileTests TapCalibrationSettingsTests HUDMapTests ExplorerTileLayerTests ExplorerTransferTests WindowGroupTests ReservedGroupTests UnifiedBindingScopeTests; do
  xcrun swiftc -j 4 "${common[@]}" "Rotagivan/Tests/$test.swift" -o "$test_dir/$test"
  "$test_dir/$test"
done
xcrun swiftc -j 4 "${common[@]}" Rotagivan/HotkeyOrganizer.swift Rotagivan/Tests/HotkeyOrganizerTests.swift -o "$test_dir/HotkeyOrganizerTests"
"$test_dir/HotkeyOrganizerTests"
xcrun swiftc -j 4 "${common[@]}" Rotagivan/HotkeyOrganizer.swift Rotagivan/Tests/MacroAuditTests.swift -o "$test_dir/MacroAuditTests"
"$test_dir/MacroAuditTests"
xcrun swiftc -j 4 "${common[@]}" Rotagivan/MotionCurveEditor.swift Rotagivan/Tests/LiveCursorPreviewTests.swift \
  -framework AppKit -framework SwiftUI -o "$test_dir/LiveCursorPreviewTests"
"$test_dir/LiveCursorPreviewTests" "$test_dir"
for test in ProfileStorageTests ProfileActivationTests ShortcutRecorderTests; do
  xcrun swiftc -j 4 "${common[@]}" Rotagivan/HotKeyManager.swift Rotagivan/ShortcutRecorder.swift \
    Rotagivan/ActionPicker.swift Rotagivan/BindingEditor.swift Rotagivan/ExplorerApplicationCatalog.swift \
    "Rotagivan/Tests/$test.swift" -framework AppKit -framework SwiftUI -framework Carbon -o "$test_dir/$test"
  "$test_dir/$test"
done
for test in ClickTests ParagraphSelectionTests; do
  xcrun swiftc -j 4 "${common[@]}" Rotagivan/EventPoster.swift Rotagivan/MacroPlayback.swift "Rotagivan/Tests/$test.swift" \
    -framework AppKit -framework CoreGraphics -o "$test_dir/$test"
  "$test_dir/$test"
done
xcrun swiftc -j 4 Rotagivan/TrackpadReport.swift Rotagivan/Tests/ReportTests.swift -o "$test_dir/ReportTests"
"$test_dir/ReportTests"
xcrun swiftc -j 4 Rotagivan/TrackpadInputRouting.swift Rotagivan/Tests/TrackpadInputRoutingTests.swift -o "$test_dir/TrackpadInputRoutingTests"
"$test_dir/TrackpadInputRoutingTests"
xcrun swiftc -j 4 Rotagivan/TrackpadInputRouting.swift Rotagivan/ExplorerPointerLock.swift \
  Rotagivan/Tests/ExplorerPointerLockTests.swift -framework CoreGraphics -o "$test_dir/ExplorerPointerLockTests"
"$test_dir/ExplorerPointerLockTests"
xcrun swiftc -j 4 Rotagivan/TrackpadReport.swift Rotagivan/TrackpadDistance.swift Rotagivan/AppleTrackpadInput.swift \
  Rotagivan/Tests/AppleTrackpadInputTests.swift -framework AppKit -framework IOKit -o "$test_dir/AppleTrackpadInputTests"
"$test_dir/AppleTrackpadInputTests"
xcrun swiftc -j 4 Rotagivan/TrackpadDistance.swift Rotagivan/Tests/TrackpadDistanceTests.swift -o "$test_dir/TrackpadDistanceTests"
"$test_dir/TrackpadDistanceTests"
xcrun swiftc -j 4 "${common[@]}" Rotagivan/TrackpadReport.swift Rotagivan/EventPoster.swift Rotagivan/MacroPlayback.swift \
  Rotagivan/DoubleTapSwipe.swift Rotagivan/GestureEngine.swift Rotagivan/Tests/DoubleTapSwipeTests.swift \
  -framework AppKit -framework CoreGraphics -o "$test_dir/DoubleTapSwipeTests"
"$test_dir/DoubleTapSwipeTests"
xcrun swiftc -j 4 "${common[@]}" Rotagivan/TrackpadReport.swift Rotagivan/EventPoster.swift Rotagivan/MacroPlayback.swift \
  Rotagivan/DoubleTapSwipe.swift Rotagivan/GestureEngine.swift Rotagivan/Tests/TwoFingerTapSwipeTests.swift \
  -framework AppKit -framework CoreGraphics -o "$test_dir/TwoFingerTapSwipeTests"
"$test_dir/TwoFingerTapSwipeTests"
xcrun swiftc -j 4 "${common[@]}" Rotagivan/TrackpadReport.swift Rotagivan/EventPoster.swift Rotagivan/MacroPlayback.swift \
  Rotagivan/DoubleTapSwipe.swift Rotagivan/GestureEngine.swift Rotagivan/Tests/NativeTrackpadGestureTests.swift \
  -framework AppKit -framework CoreGraphics -o "$test_dir/NativeTrackpadGestureTests"
"$test_dir/NativeTrackpadGestureTests"
xcrun swiftc -j 4 "${common[@]}" Rotagivan/TrackpadReport.swift Rotagivan/GestureCalibration.swift \
  Rotagivan/Tests/GestureCalibrationTests.swift -o "$test_dir/GestureCalibrationTests"
"$test_dir/GestureCalibrationTests"
xcrun swiftc -j 4 "${common[@]}" Rotagivan/Tests/SwipeDirectionTests.swift -o "$test_dir/SwipeDirectionTests"
"$test_dir/SwipeDirectionTests"
xcrun swiftc -j 4 "${common[@]}" Rotagivan/TrackpadReport.swift Rotagivan/AppExplorerSelection.swift \
  Rotagivan/Tests/AppExplorerTests.swift -o "$test_dir/AppExplorerTests"
"$test_dir/AppExplorerTests"
xcrun swiftc -j 4 "${common[@]}" Rotagivan/TrackpadReport.swift Rotagivan/AppExplorerSelection.swift \
  Rotagivan/Tests/ExplorerCapacityTests.swift -o "$test_dir/ExplorerCapacityTests"
"$test_dir/ExplorerCapacityTests"
xcrun swiftc -j 4 "${common[@]}" Rotagivan/ExplorerApplicationCatalog.swift Rotagivan/Tests/ExplorerApplicationCatalogTests.swift \
  -framework AppKit -o "$test_dir/ExplorerApplicationCatalogTests"
"$test_dir/ExplorerApplicationCatalogTests"
xcrun swiftc -j 4 "${common[@]}" Rotagivan/BrowserBookmarks.swift Rotagivan/Tests/BrowserBookmarkTests.swift \
  -o "$test_dir/BrowserBookmarkTests"
"$test_dir/BrowserBookmarkTests"
xcrun swiftc -j 4 "${common[@]}" Rotagivan/WebsiteFavicon.swift Rotagivan/Tests/FaviconTests.swift \
  -framework AppKit -framework SwiftUI -o "$test_dir/FaviconTests"
"$test_dir/FaviconTests"
xcrun swiftc -j 4 "${common[@]}" Rotagivan/WindowTiling.swift Rotagivan/Tests/WindowTilingTests.swift \
  -framework AppKit -framework SwiftUI -o "$test_dir/WindowTilingTests"
"$test_dir/WindowTilingTests"
xcrun swiftc -j 4 "${common[@]}" Rotagivan/WindowTiling.swift Rotagivan/ExplorerAppearance.swift Rotagivan/Tests/StarburstTests.swift \
  -framework AppKit -framework SwiftUI -o "$test_dir/StarburstTests"
"$test_dir/StarburstTests"
xcrun swiftc -j 4 "${common[@]}" Rotagivan/WindowTiling.swift Rotagivan/Tests/ExplorerCursorCenteringTests.swift \
  -framework AppKit -framework SwiftUI -o "$test_dir/ExplorerCursorCenteringTests"
"$test_dir/ExplorerCursorCenteringTests"
xcrun swiftc -j 4 "${common[@]}" Rotagivan/WindowTiling.swift Rotagivan/MediaControls.swift Rotagivan/Tests/ExplorerLayerMediaTests.swift \
  -framework AppKit -framework SwiftUI -o "$test_dir/ExplorerLayerMediaTests"
"$test_dir/ExplorerLayerMediaTests"
xcrun swiftc -j 4 "${common[@]}" Rotagivan/TrackpadReport.swift Rotagivan/DoubleTapSwipe.swift \
  Rotagivan/Tests/AppOverrideTests.swift -o "$test_dir/AppOverrideTests"
"$test_dir/AppOverrideTests"
xcrun swiftc -j 4 "${common[@]}" Rotagivan/TrackpadReport.swift Rotagivan/EventPoster.swift Rotagivan/MacroPlayback.swift \
  Rotagivan/DoubleTapSwipe.swift Rotagivan/GestureEngine.swift Rotagivan/Tests/TapActionTests.swift \
  -framework AppKit -framework CoreGraphics -o "$test_dir/TapActionTests"
"$test_dir/TapActionTests"
xcrun swiftc -j 4 "${common[@]}" Rotagivan/TrackpadReport.swift Rotagivan/EventPoster.swift Rotagivan/MacroPlayback.swift \
  Rotagivan/DoubleTapSwipe.swift Rotagivan/GestureEngine.swift Rotagivan/Tests/MacroActionTests.swift \
  -framework AppKit -framework CoreGraphics -o "$test_dir/MacroActionTests"
"$test_dir/MacroActionTests"
xcrun swiftc -j 4 "${common[@]}" Rotagivan/EventPoster.swift Rotagivan/MacroPlayback.swift Rotagivan/Tests/MacroPlaybackTests.swift \
  -framework AppKit -framework CoreGraphics -o "$test_dir/MacroPlaybackTests"
"$test_dir/MacroPlaybackTests"
xcrun swiftc -j 4 "${common[@]}" Rotagivan/TrackpadReport.swift Rotagivan/EventPoster.swift Rotagivan/MacroPlayback.swift \
  Rotagivan/DoubleTapSwipe.swift Rotagivan/GestureEngine.swift Rotagivan/Tests/StationaryTapTests.swift \
  -framework AppKit -framework CoreGraphics -o "$test_dir/StationaryTapTests"
"$test_dir/StationaryTapTests"
xcrun swiftc -j 4 "${common[@]}" Rotagivan/TrackpadReport.swift Rotagivan/EventPoster.swift Rotagivan/MacroPlayback.swift \
  Rotagivan/DoubleTapSwipe.swift Rotagivan/GestureEngine.swift Rotagivan/Tests/ScrollResponseIntegrationTests.swift \
  -framework AppKit -framework CoreGraphics -o "$test_dir/ScrollResponseIntegrationTests"
"$test_dir/ScrollResponseIntegrationTests"
xcrun swiftc -j 4 "${common[@]}" Rotagivan/TrackpadReport.swift Rotagivan/EventPoster.swift Rotagivan/MacroPlayback.swift \
  Rotagivan/DoubleTapSwipe.swift Rotagivan/GestureEngine.swift Rotagivan/Tests/PointerLayerIsolationTests.swift \
  -framework AppKit -framework CoreGraphics -o "$test_dir/PointerLayerIsolationTests"
"$test_dir/PointerLayerIsolationTests"
ui_sources=("${common[@]}" Rotagivan/TrackpadReport.swift Rotagivan/EventPoster.swift Rotagivan/MacroPlayback.swift \
  Rotagivan/DoubleTapSwipe.swift Rotagivan/GestureEngine.swift Rotagivan/GestureCalibration.swift \
  Rotagivan/GestureCalibrationView.swift Rotagivan/AppExplorerSelection.swift Rotagivan/VaultCrypto.swift Rotagivan/CredentialVault.swift Rotagivan/CredentialVaultView.swift Rotagivan/VoiceActions.swift Rotagivan/VoiceRecognition.swift Rotagivan/AppExplorer.swift \
  Rotagivan/HotKeyManager.swift Rotagivan/ShortcutRecorder.swift Rotagivan/AppExplorerSettingsView.swift \
  Rotagivan/ExplorerApplicationCatalog.swift Rotagivan/BrowserBookmarks.swift Rotagivan/ExplorerDestinationPicker.swift \
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
  Rotagivan/HIDManager.swift)
xcrun swiftc -j 4 -I "$yaml_build/Modules" -I YAML/.build/checkouts/Yams/Sources/CYaml/include \
  -L "$yaml_build" -lConfigurationYAML "${ui_sources[@]}" Rotagivan/AppConfiguration.swift Rotagivan/SyncStorage.swift \
  Rotagivan/ActionTableRow.swift Rotagivan/HotkeyOrganizerView.swift Rotagivan/ApplicationCommandEditor.swift Rotagivan/Tests/ActionTableTests.swift \
  -framework AppKit -framework SwiftUI -framework AVFoundation -framework CoreGraphics -framework IOKit -framework Carbon -o "$test_dir/ActionTableTests"
"$test_dir/ActionTableTests" "$test_dir"
xcrun swiftc -j 4 -I "$yaml_build/Modules" -I YAML/.build/checkouts/Yams/Sources/CYaml/include \
  -L "$yaml_build" -lConfigurationYAML "${ui_sources[@]}" Rotagivan/AppConfiguration.swift Rotagivan/SyncStorage.swift \
  Rotagivan/ActionTableRow.swift Rotagivan/HotkeyOrganizerView.swift Rotagivan/ApplicationCommandEditor.swift Rotagivan/Tests/ApplicationCommandUISmoke.swift \
  -framework AppKit -framework SwiftUI -framework AVFoundation -framework CoreGraphics -framework IOKit -framework Carbon -o "$test_dir/ApplicationCommandUISmoke"
"$test_dir/ApplicationCommandUISmoke" "$test_dir"
for test in ApplicationCommandTests BrowserURLDispatcherTests; do
  xcrun swiftc -j 4 "${ui_sources[@]}" "Rotagivan/Tests/$test.swift" \
    -framework AppKit -framework SwiftUI -framework AVFoundation -framework CoreGraphics -framework IOKit -framework Carbon -o "$test_dir/$test"
  "$test_dir/$test"
done
xcrun swiftc -j 4 "${ui_sources[@]}" Rotagivan/Tests/ActionPickerTests.swift \
  -framework AppKit -framework SwiftUI -framework AVFoundation -framework CoreGraphics -framework IOKit -framework Carbon -o "$test_dir/ActionPickerTests"
"$test_dir/ActionPickerTests" "$test_dir"
xcrun swiftc -j 4 "${ui_sources[@]}" Rotagivan/Tests/HUDTemplateTests.swift \
  -framework AppKit -framework SwiftUI -framework AVFoundation -framework CoreGraphics -framework IOKit -framework Carbon -o "$test_dir/HUDTemplateTests"
"$test_dir/HUDTemplateTests"
xcrun swiftc -j 4 Rotagivan/VaultCrypto.swift Rotagivan/Tests/VaultCryptoTests.swift -framework Security -o "$test_dir/VaultCryptoTests"
"$test_dir/VaultCryptoTests"
for test in CredentialVaultTests VaultRestoreUISmoke; do
xcrun swiftc -j 4 "${common[@]}" Rotagivan/ExplorerApplicationCatalog.swift Rotagivan/VoiceActions.swift \
  Rotagivan/VaultCrypto.swift Rotagivan/CredentialVault.swift Rotagivan/CredentialVaultView.swift "Rotagivan/Tests/$test.swift" \
  -framework AppKit -framework SwiftUI -framework Security -o "$test_dir/$test"
"$test_dir/$test" "$test_dir"
done
xcrun swiftc -j 4 "${ui_sources[@]}" Rotagivan/Tests/VoiceTests.swift \
  -framework AppKit -framework SwiftUI -framework AVFoundation -framework CoreGraphics -framework IOKit -framework Carbon -o "$test_dir/VoiceTests"
"$test_dir/VoiceTests" "$test_dir"
xcrun swiftc -j 4 "${ui_sources[@]}" Rotagivan/Tests/VoiceHUDUISmoke.swift \
  -framework AppKit -framework SwiftUI -framework AVFoundation -framework CoreGraphics -framework IOKit -framework Carbon -o "$test_dir/VoiceHUDUISmoke"
"$test_dir/VoiceHUDUISmoke" "$test_dir"
xcrun swiftc -j 4 "${ui_sources[@]}" Rotagivan/Tests/VoiceApplicationIndexTests.swift \
  -framework AppKit -framework SwiftUI -framework AVFoundation -framework CoreGraphics -framework IOKit -framework Carbon -o "$test_dir/VoiceApplicationIndexTests"
"$test_dir/VoiceApplicationIndexTests"
xcrun swiftc -j 4 "${ui_sources[@]}" Rotagivan/Tests/CalibrationIntegrationTests.swift \
  -framework AppKit -framework SwiftUI -framework CoreGraphics -framework IOKit -framework Carbon -o "$test_dir/CalibrationIntegrationTests"
"$test_dir/CalibrationIntegrationTests"
xcrun swiftc -j 4 "${ui_sources[@]}" Rotagivan/Tests/HUDBindingUISmoke.swift \
  -framework AppKit -framework SwiftUI -framework CoreGraphics -framework IOKit -framework Carbon -o "$test_dir/HUDBindingUISmoke"
"$test_dir/HUDBindingUISmoke" "$test_dir"
xcrun swiftc -j 4 "${ui_sources[@]}" Rotagivan/Tests/ActionBindingRuntimeTests.swift \
  -framework AppKit -framework SwiftUI -framework CoreGraphics -framework IOKit -framework Carbon -o "$test_dir/ActionBindingRuntimeTests"
"$test_dir/ActionBindingRuntimeTests"
xcrun swiftc -j 4 -I "$yaml_build/Modules" -I YAML/.build/checkouts/Yams/Sources/CYaml/include \
  -L "$yaml_build" -lConfigurationYAML "${common[@]}" Rotagivan/HotKeyManager.swift \
  Rotagivan/AppConfiguration.swift Rotagivan/SyncStorage.swift Rotagivan/Tests/ConfigurationTests.swift \
  -framework AppKit -framework Carbon -framework Security -o "$test_dir/ConfigurationTests"
"$test_dir/ConfigurationTests"
xcrun swiftc -j 4 -I "$yaml_build/Modules" -I YAML/.build/checkouts/Yams/Sources/CYaml/include \
  -L "$yaml_build" -lConfigurationYAML "${common[@]}" Rotagivan/HotKeyManager.swift \
  Rotagivan/AppConfiguration.swift Rotagivan/SyncStorage.swift Rotagivan/Tests/SyncStorageTests.swift \
  -framework AppKit -framework Carbon -framework Security -o "$test_dir/SyncStorageTests"
"$test_dir/SyncStorageTests"
for test in ManualSyncTests CredentialLifecycleTests; do
xcrun swiftc -j 4 -I "$yaml_build/Modules" -I YAML/.build/checkouts/Yams/Sources/CYaml/include \
  -L "$yaml_build" -lConfigurationYAML $ui_sources Rotagivan/AppConfiguration.swift \
  Rotagivan/SyncStorage.swift Rotagivan/SettingsSync.swift Rotagivan/SyncSettingsView.swift "Rotagivan/Tests/$test.swift" \
  -framework AppKit -framework SwiftUI -framework CoreGraphics -framework IOKit -framework Carbon -framework Security \
  -o "$test_dir/$test"
"$test_dir/$test" "$test_dir"
done
# Compile settings tests from the same source list as the app, excluding its entry point.
settings_sources=()
while IFS= read -r source; do
  settings_sources+=("Rotagivan/$source")
done < <(sed -n 's/^  "$script_dir\/\(.*\.swift\)" \\/\1/p' Rotagivan/build.sh | rg -v '^RotagivanApp.swift$')
xcrun swiftc -j 4 -I "$yaml_build/Modules" -I YAML/.build/checkouts/Yams/Sources/CYaml/include \
  -L "$yaml_build" -lConfigurationYAML "${settings_sources[@]}" Rotagivan/Tests/ReleaseSettingsTests.swift \
  -framework AppKit -framework SwiftUI -framework AVFoundation -framework CoreGraphics -framework IOKit \
  -framework Carbon -framework Security -framework ServiceManagement -o "$test_dir/ReleaseSettingsTests"
"$test_dir/ReleaseSettingsTests" "$test_dir"
echo "All tests passed. Test binaries: $test_dir"
