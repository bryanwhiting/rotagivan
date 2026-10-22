#!/bin/zsh
set -euo pipefail
script_dir=${0:A:h}
cd "$script_dir/.."
test_dir=$(mktemp -d "${TMPDIR:-/private/tmp}/rota-tests.XXXXXX")
# Tests create throwaway UserDefaults suites, which land in ~/Library/Preferences
# and survive a failed precondition. Sweep them whenever the run ends so they do
# not accumulate (tens of thousands were found) and slow cfprefsd for every app.
cleanup_test_preferences() {
  local uuid='[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}'
  # The (givan)? alternatives still sweep suites left behind by runs before the rename.
  ls "$HOME/Library/Preferences" 2>/dev/null | grep -E "^(Rota(givan)?\.[A-Za-z]+\.${uuid}\.plist|Rota(givan)?SettingsTests\.${uuid}\.plist|local\.rota(givan)?\.(activation-test|external-shortcut-test|shortcut-atlas-fixture|tests\.[a-z-]+)\.${uuid}(\.settings)?\.plist|local\.rota(givan)?\.typing-test\.plist|rota(givan)?-[0-9]+-[a-zA-Z-]+\.plist|rota(givan)?-actions-organizer-smoke\.plist)$" \
    | while IFS= read -r name; do rm -f "$HOME/Library/Preferences/$name"; done
}
trap cleanup_test_preferences EXIT
xcrun swiftc Rota/AccessibilitySetup.swift Rota/UIComponents.swift Rota/Tests/AccessibilitySetupTests.swift -framework AppKit -framework SwiftUI -o "$test_dir/AccessibilitySetupTests"
"$test_dir/AccessibilitySetupTests" "$test_dir"
swift build --package-path YAML -c release --product ConfigurationYAML
yaml_build=$(swift build --package-path YAML -c release --show-bin-path)
common=(Rota/Models.swift Rota/AppOverrides.swift Rota/CursorResponse.swift Rota/ScrollResponse.swift Rota/TrackpadDistance.swift Rota/SwipeDirectionClassification.swift Rota/CredentialWorker.swift)
xcrun swiftc -j 4 "${common[@]}" Rota/Tests/HUDLauncherTests.swift -framework Security -o "$test_dir/HUDLauncherTests"
"$test_dir/HUDLauncherTests"
xcrun swiftc -j 4 Rota/TemporaryIntention.swift Rota/Tests/TemporaryIntentionTests.swift -o "$test_dir/TemporaryIntentionTests"
"$test_dir/TemporaryIntentionTests"
xcrun swiftc -j 4 Rota/VoiceMicrophoneAdmission.swift Rota/Tests/VoiceMicrophoneAdmissionTests.swift \
  -o "$test_dir/VoiceMicrophoneAdmissionTests"
"$test_dir/VoiceMicrophoneAdmissionTests"
xcrun swiftc -j 4 Rota/VoiceInputDevice.swift Rota/UIComponents.swift Rota/Tests/VoiceInputDeviceTests.swift \
  -framework AppKit -framework SwiftUI -framework AVFoundation -o "$test_dir/VoiceInputDeviceTests"
"$test_dir/VoiceInputDeviceTests"
xcrun swiftc -j 4 Rota/VoiceMicrophoneAdmission.swift Rota/TemporaryIntention.swift Rota/UIComponents.swift \
  Rota/VoiceInputDevice.swift Rota/LocalIntentionSpeech.swift Rota/Tests/LocalIntentionSpeechTests.swift \
  -framework AppKit -framework SwiftUI -framework Speech -framework AVFoundation -o "$test_dir/LocalIntentionSpeechTests"
"$test_dir/LocalIntentionSpeechTests"
for test in CursorResponseTests CursorGainTests CursorTelemetryTests ScrollResponseTests ConfigurationProfileTests PointerProfileTests TapCalibrationSettingsTests HUDMapTests ExplorerTileLayerTests ExplorerTransferTests WindowGroupTests ReservedGroupTests UnifiedBindingScopeTests; do
  xcrun swiftc -j 4 "${common[@]}" "Rota/Tests/$test.swift" -o "$test_dir/$test"
  "$test_dir/$test"
done
xcrun swiftc -j 4 "${common[@]}" Rota/UpdateChecker.swift Rota/Tests/UpdateCheckerTests.swift \
  -framework AppKit -framework Security -o "$test_dir/UpdateCheckerTests"
"$test_dir/UpdateCheckerTests"
xcrun swiftc -j 4 "${common[@]}" Rota/HotkeyOrganizer.swift Rota/Tests/HotkeyOrganizerTests.swift -o "$test_dir/HotkeyOrganizerTests"
"$test_dir/HotkeyOrganizerTests"
xcrun swiftc -j 4 "${common[@]}" Rota/HotkeyOrganizer.swift Rota/HotKeyManager.swift \
  Rota/ExplorerApplicationCatalog.swift Rota/ApplicationIndex.swift Rota/ApplicationIndexObservation.swift \
  Rota/SyncCrypto.swift Rota/VoiceActions.swift Rota/ActionTableRow.swift Rota/ActionCatalogSnapshot.swift \
  Rota/Tests/ActionCatalogSnapshotTests.swift -framework AppKit -framework Carbon -framework Security \
  -o "$test_dir/ActionCatalogSnapshotTests"
"$test_dir/ActionCatalogSnapshotTests"
xcrun swiftc -j 4 "${common[@]}" Rota/HotkeyOrganizer.swift Rota/HotKeyManager.swift \
  Rota/ExplorerApplicationCatalog.swift Rota/ApplicationIndex.swift Rota/ApplicationIndexObservation.swift \
  Rota/SyncCrypto.swift Rota/VoiceActions.swift Rota/ActionTableRow.swift \
  Rota/MCPProtocol.swift Rota/MCPSettingsTools.swift Rota/MCPBridge.swift \
  Rota/Tests/MCPTests.swift -framework AppKit -framework Carbon -framework Security -o "$test_dir/MCPTests"
"$test_dir/MCPTests"
xcrun swiftc -j 4 "${common[@]}" Rota/HotkeyOrganizer.swift Rota/Tests/MacroAuditTests.swift -o "$test_dir/MacroAuditTests"
"$test_dir/MacroAuditTests"
xcrun swiftc -j 4 -I "$yaml_build/Modules" -I YAML/.build/checkouts/Yams/Sources/CYaml/include \
  -L "$yaml_build" -lConfigurationYAML "${common[@]}" Rota/HotKeyManager.swift \
  Rota/AppConfiguration.swift Rota/SyncStorage.swift Rota/MacroPack.swift Rota/Tests/MacroPackTests.swift \
  -framework AppKit -framework Carbon -framework Security -o "$test_dir/MacroPackTests"
"$test_dir/MacroPackTests"
xcrun swiftc -j 4 "${common[@]}" Rota/MotionCurveEditor.swift Rota/UIComponents.swift Rota/Tests/LiveCursorPreviewTests.swift \
  -framework AppKit -framework SwiftUI -o "$test_dir/LiveCursorPreviewTests"
"$test_dir/LiveCursorPreviewTests" "$test_dir"
for test in ProfileStorageTests ProfileActivationTests ShortcutRecorderTests; do
  xcrun swiftc -j 4 "${common[@]}" Rota/HotKeyManager.swift Rota/ShortcutRecorder.swift \
    Rota/ActionPicker.swift Rota/BindingEditor.swift Rota/ExplorerApplicationCatalog.swift \
    Rota/ApplicationIndex.swift Rota/ApplicationIndexObservation.swift \
    Rota/UIComponents.swift "Rota/Tests/$test.swift" -framework AppKit -framework SwiftUI -framework Carbon -o "$test_dir/$test"
  "$test_dir/$test"
done
for test in ClickTests ParagraphSelectionTests; do
  xcrun swiftc -j 4 "${common[@]}" Rota/EventPoster.swift Rota/MacroPlayback.swift "Rota/Tests/$test.swift" \
    -framework AppKit -framework CoreGraphics -o "$test_dir/$test"
  "$test_dir/$test"
done
xcrun swiftc -j 4 Rota/TrackpadReport.swift Rota/Tests/ReportTests.swift -o "$test_dir/ReportTests"
"$test_dir/ReportTests"
xcrun swiftc -j 4 Rota/TrackpadInputRouting.swift Rota/Tests/TrackpadInputRoutingTests.swift -o "$test_dir/TrackpadInputRoutingTests"
"$test_dir/TrackpadInputRoutingTests"
xcrun swiftc -j 4 Rota/TrackpadReport.swift Rota/TrackpadInputRouting.swift Rota/DeviceDiagnosticsCore.swift \
  Rota/Tests/DeviceDiagnosticsTests.swift -o "$test_dir/DeviceDiagnosticsTests"
"$test_dir/DeviceDiagnosticsTests"
xcrun swiftc -j 4 Rota/TrackpadInputRouting.swift Rota/ExplorerPointerLock.swift \
  Rota/Tests/ExplorerPointerLockTests.swift -framework CoreGraphics -o "$test_dir/ExplorerPointerLockTests"
"$test_dir/ExplorerPointerLockTests"
xcrun swiftc -j 4 Rota/TrackpadReport.swift Rota/TrackpadDistance.swift Rota/AppleTrackpadInput.swift \
  Rota/Tests/AppleTrackpadInputTests.swift -framework AppKit -framework IOKit -o "$test_dir/AppleTrackpadInputTests"
"$test_dir/AppleTrackpadInputTests"
xcrun swiftc -j 4 Rota/TrackpadDistance.swift Rota/Tests/TrackpadDistanceTests.swift -o "$test_dir/TrackpadDistanceTests"
"$test_dir/TrackpadDistanceTests"
xcrun swiftc -j 4 "${common[@]}" Rota/TrackpadReport.swift Rota/EventPoster.swift Rota/MacroPlayback.swift \
  Rota/DoubleTapSwipe.swift Rota/GestureEngine.swift Rota/Tests/DoubleTapSwipeTests.swift \
  -framework AppKit -framework CoreGraphics -o "$test_dir/DoubleTapSwipeTests"
"$test_dir/DoubleTapSwipeTests"
xcrun swiftc -j 4 "${common[@]}" Rota/TrackpadReport.swift Rota/EventPoster.swift Rota/MacroPlayback.swift \
  Rota/DoubleTapSwipe.swift Rota/GestureEngine.swift Rota/Tests/TwoFingerTapSwipeTests.swift \
  -framework AppKit -framework CoreGraphics -o "$test_dir/TwoFingerTapSwipeTests"
"$test_dir/TwoFingerTapSwipeTests"
xcrun swiftc -j 4 "${common[@]}" Rota/TrackpadReport.swift Rota/EventPoster.swift Rota/MacroPlayback.swift \
  Rota/DoubleTapSwipe.swift Rota/GestureEngine.swift Rota/Tests/NativeTrackpadGestureTests.swift \
  -framework AppKit -framework CoreGraphics -o "$test_dir/NativeTrackpadGestureTests"
"$test_dir/NativeTrackpadGestureTests"
xcrun swiftc -j 4 "${common[@]}" Rota/TrackpadReport.swift Rota/GestureCalibration.swift \
  Rota/Tests/GestureCalibrationTests.swift -o "$test_dir/GestureCalibrationTests"
"$test_dir/GestureCalibrationTests"
xcrun swiftc -j 4 "${common[@]}" Rota/Tests/SwipeDirectionTests.swift -o "$test_dir/SwipeDirectionTests"
"$test_dir/SwipeDirectionTests"
xcrun swiftc -j 4 "${common[@]}" Rota/TrackpadReport.swift Rota/AppExplorerSelection.swift \
  Rota/Tests/AppExplorerTests.swift -o "$test_dir/AppExplorerTests"
"$test_dir/AppExplorerTests"
xcrun swiftc -j 4 "${common[@]}" Rota/TrackpadReport.swift Rota/AppExplorerSelection.swift \
  Rota/Tests/ExplorerCapacityTests.swift -o "$test_dir/ExplorerCapacityTests"
"$test_dir/ExplorerCapacityTests"
xcrun swiftc -j 4 "${common[@]}" Rota/ExplorerApplicationCatalog.swift Rota/Tests/ExplorerApplicationCatalogTests.swift \
  -framework AppKit -o "$test_dir/ExplorerApplicationCatalogTests"
"$test_dir/ExplorerApplicationCatalogTests"
xcrun swiftc -j 4 "${common[@]}" Rota/BrowserBookmarks.swift Rota/Tests/BrowserBookmarkTests.swift \
  -o "$test_dir/BrowserBookmarkTests"
"$test_dir/BrowserBookmarkTests"
xcrun swiftc -j 4 "${common[@]}" Rota/UIComponents.swift Rota/WebsiteFavicon.swift Rota/Tests/FaviconTests.swift \
  -framework AppKit -framework SwiftUI -o "$test_dir/FaviconTests"
"$test_dir/FaviconTests"
xcrun swiftc -j 4 "${common[@]}" Rota/WindowTiling.swift Rota/Tests/WindowTilingTests.swift \
  -framework AppKit -framework SwiftUI -o "$test_dir/WindowTilingTests"
"$test_dir/WindowTilingTests"
xcrun swiftc -j 4 "${common[@]}" Rota/UIComponents.swift Rota/WindowTiling.swift Rota/ExplorerAppearance.swift Rota/Tests/StarburstTests.swift \
  -framework AppKit -framework SwiftUI -o "$test_dir/StarburstTests"
"$test_dir/StarburstTests"
xcrun swiftc -j 4 "${common[@]}" Rota/WindowTiling.swift Rota/Tests/ExplorerCursorCenteringTests.swift \
  -framework AppKit -framework SwiftUI -o "$test_dir/ExplorerCursorCenteringTests"
"$test_dir/ExplorerCursorCenteringTests"
xcrun swiftc -j 4 "${common[@]}" Rota/WindowTiling.swift Rota/MediaControls.swift Rota/Tests/ExplorerLayerMediaTests.swift \
  -framework AppKit -framework SwiftUI -o "$test_dir/ExplorerLayerMediaTests"
"$test_dir/ExplorerLayerMediaTests"
xcrun swiftc -j 4 "${common[@]}" Rota/TrackpadReport.swift Rota/DoubleTapSwipe.swift \
  Rota/Tests/AppOverrideTests.swift -o "$test_dir/AppOverrideTests"
"$test_dir/AppOverrideTests"
xcrun swiftc -j 4 "${common[@]}" Rota/TrackpadReport.swift Rota/EventPoster.swift Rota/MacroPlayback.swift \
  Rota/DoubleTapSwipe.swift Rota/GestureEngine.swift Rota/Tests/TapActionTests.swift \
  -framework AppKit -framework CoreGraphics -o "$test_dir/TapActionTests"
"$test_dir/TapActionTests"
xcrun swiftc -j 4 "${common[@]}" Rota/TrackpadReport.swift Rota/EventPoster.swift Rota/MacroPlayback.swift \
  Rota/DoubleTapSwipe.swift Rota/GestureEngine.swift Rota/Tests/MacroActionTests.swift \
  -framework AppKit -framework CoreGraphics -o "$test_dir/MacroActionTests"
"$test_dir/MacroActionTests"
xcrun swiftc -j 4 "${common[@]}" Rota/EventPoster.swift Rota/MacroPlayback.swift Rota/Tests/MacroPlaybackTests.swift \
  -framework AppKit -framework CoreGraphics -o "$test_dir/MacroPlaybackTests"
"$test_dir/MacroPlaybackTests"
xcrun swiftc -j 4 "${common[@]}" Rota/TrackpadReport.swift Rota/EventPoster.swift Rota/MacroPlayback.swift \
  Rota/DoubleTapSwipe.swift Rota/GestureEngine.swift Rota/Tests/StationaryTapTests.swift \
  -framework AppKit -framework CoreGraphics -o "$test_dir/StationaryTapTests"
"$test_dir/StationaryTapTests"
xcrun swiftc -j 4 "${common[@]}" Rota/TrackpadReport.swift Rota/EventPoster.swift Rota/MacroPlayback.swift \
  Rota/DoubleTapSwipe.swift Rota/GestureEngine.swift Rota/Tests/ScrollResponseIntegrationTests.swift \
  -framework AppKit -framework CoreGraphics -o "$test_dir/ScrollResponseIntegrationTests"
"$test_dir/ScrollResponseIntegrationTests"
xcrun swiftc -j 4 "${common[@]}" Rota/TrackpadReport.swift Rota/EventPoster.swift Rota/MacroPlayback.swift \
  Rota/DoubleTapSwipe.swift Rota/GestureEngine.swift Rota/Tests/CursorJumpGuardTests.swift \
  -framework AppKit -framework CoreGraphics -o "$test_dir/CursorJumpGuardTests"
"$test_dir/CursorJumpGuardTests"
xcrun swiftc -j 4 "${common[@]}" Rota/TrackpadReport.swift Rota/EventPoster.swift Rota/MacroPlayback.swift \
  Rota/DoubleTapSwipe.swift Rota/GestureEngine.swift Rota/Tests/PointerLayerIsolationTests.swift \
  -framework AppKit -framework CoreGraphics -o "$test_dir/PointerLayerIsolationTests"
"$test_dir/PointerLayerIsolationTests"
ui_sources=("${common[@]}" Rota/UIComponents.swift Rota/TrackpadReport.swift Rota/EventPoster.swift Rota/MacroPlayback.swift \
  Rota/TemporaryIntention.swift Rota/TemporaryIntentionView.swift \
  Rota/VoiceMicrophoneAdmission.swift Rota/VoiceInputDevice.swift Rota/NoteDictationSession.swift \
  Rota/DoubleTapSwipe.swift Rota/GestureEngine.swift Rota/GestureCalibration.swift \
  Rota/GestureCalibrationView.swift Rota/AppExplorerSelection.swift Rota/SyncCrypto.swift Rota/VoiceActions.swift Rota/VoiceRecognition.swift Rota/OpenAIRealtime.swift Rota/LauncherActions.swift Rota/AppExplorer.swift \
  Rota/HotKeyManager.swift Rota/ShortcutRecorder.swift Rota/AppExplorerSettingsView.swift \
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
  Rota/AccessibilitySetup.swift Rota/DeviceDiagnosticsCore.swift Rota/HIDManager.swift Rota/SlackChannels.swift Rota/FocusTimer.swift -lsqlite3)
for test in ActionTableTests HotkeyGestureAssignmentTests; do
xcrun swiftc -j 4 -I "$yaml_build/Modules" -I YAML/.build/checkouts/Yams/Sources/CYaml/include \
  -L "$yaml_build" -lConfigurationYAML "${ui_sources[@]}" Rota/AppConfiguration.swift Rota/SyncStorage.swift \
  Rota/ActionTableRow.swift Rota/ActionCatalogSnapshot.swift Rota/HotkeyOrganizerView.swift Rota/MacroPack.swift Rota/MacroPackImport.swift Rota/ApplicationCommandEditor.swift "Rota/Tests/$test.swift" \
  -framework AppKit -framework SwiftUI -framework AVFoundation -framework CoreGraphics -framework IOKit -framework Carbon -o "$test_dir/$test"
"$test_dir/$test" "$test_dir"
done
xcrun swiftc -j 4 -I "$yaml_build/Modules" -I YAML/.build/checkouts/Yams/Sources/CYaml/include \
  -L "$yaml_build" -lConfigurationYAML "${ui_sources[@]}" Rota/AppConfiguration.swift Rota/SyncStorage.swift \
  Rota/ActionTableRow.swift Rota/ActionCatalogSnapshot.swift Rota/HotkeyOrganizerView.swift Rota/MacroPack.swift Rota/MacroPackImport.swift Rota/ApplicationCommandEditor.swift Rota/Tests/ApplicationCommandUISmoke.swift \
  -framework AppKit -framework SwiftUI -framework AVFoundation -framework CoreGraphics -framework IOKit -framework Carbon -o "$test_dir/ApplicationCommandUISmoke"
"$test_dir/ApplicationCommandUISmoke" "$test_dir"
for test in ApplicationCommandTests BrowserURLDispatcherTests ChromeHistoryTests SlackChannelTests FocusTimerTests; do
  xcrun swiftc -j 4 "${ui_sources[@]}" "Rota/Tests/$test.swift" \
    -framework AppKit -framework SwiftUI -framework AVFoundation -framework CoreGraphics -framework IOKit -framework Carbon -o "$test_dir/$test"
  "$test_dir/$test"
done
for test in ActionPickerTests SharedApplicationPickerTests WebsiteActionTests; do
  xcrun swiftc -j 4 "${ui_sources[@]}" "Rota/Tests/$test.swift" \
    -framework AppKit -framework SwiftUI -framework AVFoundation -framework CoreGraphics -framework IOKit -framework Carbon -o "$test_dir/$test"
  "$test_dir/$test" "$test_dir"
done
xcrun swiftc -j 4 "${ui_sources[@]}" Rota/Tests/HUDTemplateTests.swift \
  -framework AppKit -framework SwiftUI -framework AVFoundation -framework CoreGraphics -framework IOKit -framework Carbon -o "$test_dir/HUDTemplateTests"
"$test_dir/HUDTemplateTests"
xcrun swiftc -j 4 Rota/SyncCrypto.swift Rota/VoiceActions.swift "${common[@]}" Rota/ExplorerApplicationCatalog.swift \
  Rota/Tests/SyncCryptoTests.swift -framework AppKit -framework Security -o "$test_dir/SyncCryptoTests"
"$test_dir/SyncCryptoTests"
xcrun swiftc -j 4 Rota/SyncCrypto.swift Rota/VoiceActions.swift "${common[@]}" Rota/ExplorerApplicationCatalog.swift \
  Rota/EncryptedSettingsCore.swift Rota/EncryptedPreferences.swift Rota/SettingsPersistence.swift \
  Rota/Tests/SettingsPersistenceTests.swift -framework AppKit -framework Security -o "$test_dir/SettingsPersistenceTests"
"$test_dir/SettingsPersistenceTests"
for test in VoiceTransportTests; do
xcrun swiftc -j 4 "${common[@]}" Rota/ExplorerApplicationCatalog.swift Rota/VoiceActions.swift Rota/TemporaryIntention.swift \
  Rota/SyncCrypto.swift Rota/UIComponents.swift "Rota/Tests/$test.swift" \
  -framework AppKit -framework SwiftUI -framework Security -o "$test_dir/$test"
"$test_dir/$test" "$test_dir"
done
xcrun swiftc -j 4 "${ui_sources[@]}" Rota/Tests/VoiceTests.swift \
  -framework AppKit -framework SwiftUI -framework AVFoundation -framework CoreGraphics -framework IOKit -framework Carbon -o "$test_dir/VoiceTests"
"$test_dir/VoiceTests" "$test_dir"
xcrun swiftc -j 4 "${ui_sources[@]}" Rota/Tests/NoteDictationTests.swift \
  -framework AppKit -framework SwiftUI -framework AVFoundation -framework CoreGraphics -framework IOKit -framework Carbon -o "$test_dir/NoteDictationTests"
"$test_dir/NoteDictationTests"
xcrun swiftc -j 4 "${ui_sources[@]}" Rota/Tests/VoiceHUDUISmoke.swift \
  -framework AppKit -framework SwiftUI -framework AVFoundation -framework CoreGraphics -framework IOKit -framework Carbon -o "$test_dir/VoiceHUDUISmoke"
"$test_dir/VoiceHUDUISmoke" "$test_dir"
for test in VoiceApplicationIndexTests ApplicationIndexObservationTests; do
  xcrun swiftc -j 4 Rota/ExplorerApplicationCatalog.swift Rota/ApplicationIndex.swift \
    Rota/ApplicationIndexObservation.swift "Rota/Tests/$test.swift" \
    -framework AppKit -framework CoreServices -o "$test_dir/$test"
  "$test_dir/$test"
done
xcrun swiftc -j 4 "${ui_sources[@]}" Rota/Tests/CalibrationIntegrationTests.swift \
  -framework AppKit -framework SwiftUI -framework CoreGraphics -framework IOKit -framework Carbon -o "$test_dir/CalibrationIntegrationTests"
"$test_dir/CalibrationIntegrationTests"
xcrun swiftc -j 4 "${ui_sources[@]}" Rota/Tests/AppleTapSwipeTests.swift \
  -framework AppKit -framework SwiftUI -framework AVFoundation -framework CoreGraphics -framework IOKit -framework Carbon -o "$test_dir/AppleTapSwipeTests"
"$test_dir/AppleTapSwipeTests"
xcrun swiftc -j 4 "${ui_sources[@]}" Rota/Tests/ExplorerAppletUISmoke.swift \
  -framework AppKit -framework SwiftUI -framework AVFoundation -framework CoreGraphics -framework IOKit -framework Carbon -o "$test_dir/ExplorerAppletUISmoke"
"$test_dir/ExplorerAppletUISmoke" "$test_dir"
xcrun swiftc -j 4 "${ui_sources[@]}" Rota/Tests/HUDBindingUISmoke.swift \
  -framework AppKit -framework SwiftUI -framework CoreGraphics -framework IOKit -framework Carbon -o "$test_dir/HUDBindingUISmoke"
"$test_dir/HUDBindingUISmoke" "$test_dir"
xcrun swiftc -j 4 "${ui_sources[@]}" Rota/Tests/ActionBindingRuntimeTests.swift \
  -framework AppKit -framework SwiftUI -framework CoreGraphics -framework IOKit -framework Carbon -o "$test_dir/ActionBindingRuntimeTests"
"$test_dir/ActionBindingRuntimeTests"
xcrun swiftc -j 4 -I "$yaml_build/Modules" -I YAML/.build/checkouts/Yams/Sources/CYaml/include \
  -L "$yaml_build" -lConfigurationYAML "${common[@]}" Rota/HotKeyManager.swift \
  Rota/AppConfiguration.swift Rota/SyncStorage.swift Rota/Tests/ConfigurationTests.swift \
  -framework AppKit -framework Carbon -framework Security -o "$test_dir/ConfigurationTests"
"$test_dir/ConfigurationTests"
xcrun swiftc -j 4 -I "$yaml_build/Modules" -I YAML/.build/checkouts/Yams/Sources/CYaml/include \
  -L "$yaml_build" -lConfigurationYAML "${common[@]}" Rota/HotKeyManager.swift \
  Rota/AppConfiguration.swift Rota/SyncStorage.swift Rota/Tests/SyncStorageTests.swift \
  -framework AppKit -framework Carbon -framework Security -o "$test_dir/SyncStorageTests"
"$test_dir/SyncStorageTests"
for test in CloudSyncEngineTests LocalSyncTests; do
xcrun swiftc -j 4 -I "$yaml_build/Modules" -I YAML/.build/checkouts/Yams/Sources/CYaml/include \
  -L "$yaml_build" -lConfigurationYAML "${common[@]}" Rota/HotKeyManager.swift \
  Rota/AppConfiguration.swift Rota/SyncStorage.swift Rota/SyncCrypto.swift \
  Rota/CloudSync.swift Rota/LocalSync.swift Rota/VoiceActions.swift Rota/ExplorerApplicationCatalog.swift \
  "Rota/Tests/$test.swift" -framework AppKit -framework Carbon -framework Security -o "$test_dir/$test"
"$test_dir/$test"
done
xcrun swiftc -j 4 -I "$yaml_build/Modules" -I YAML/.build/checkouts/Yams/Sources/CYaml/include \
  -L "$yaml_build" -lConfigurationYAML $ui_sources Rota/AppConfiguration.swift \
  Rota/SyncStorage.swift Rota/SettingsSync.swift Rota/SyncSettingsView.swift \
  Rota/EncryptedSettingsCore.swift Rota/EncryptedPreferences.swift Rota/CloudSync.swift Rota/LocalSync.swift \
  Rota/Tests/SettingsSyncTests.swift \
  -framework AppKit -framework SwiftUI -framework CoreGraphics -framework IOKit -framework Carbon -framework Security \
  -o "$test_dir/SettingsSyncTests"
"$test_dir/SettingsSyncTests" "$test_dir"
# Compile settings tests from the same source list as the app, excluding its entry point.
settings_sources=()
while IFS= read -r source; do
  settings_sources+=("Rota/$source")
done < <(sed -n '/^sources=(/,/^)/s/^  "$script_dir\/\([^"]*\.swift\)"$/\1/p' Rota/build.sh | rg -v '^RotaApp.swift$')
for test in ReleaseSettingsTests BuiltInHUDUISmoke TemporaryIntentionUISmoke HUDWorkspaceUISmoke HUDLayoutPreviewUISmoke HUDSettingsUISmoke OnboardingUISmoke; do
xcrun swiftc -j 4 -I "$yaml_build/Modules" -I YAML/.build/checkouts/Yams/Sources/CYaml/include \
  -L "$yaml_build" -lConfigurationYAML -lsqlite3 "${settings_sources[@]}" "Rota/Tests/$test.swift" \
  -framework AppKit -framework SwiftUI -framework AVFoundation -framework CoreGraphics -framework IOKit \
  -framework Carbon -framework Security -framework ServiceManagement -framework Speech -o "$test_dir/$test"
"$test_dir/$test" "$test_dir"
done
echo "All tests passed. Test binaries: $test_dir"
