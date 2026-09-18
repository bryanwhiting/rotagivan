#!/bin/zsh
set -euo pipefail
script_dir=${0:A:h}
cd "$script_dir/.."
test_dir=$(mktemp -d /private/tmp/rotagivan-tests.XXXXXX)
swift build --package-path YAML -c release --product ConfigurationYAML
yaml_build=$(swift build --package-path YAML -c release --show-bin-path)
common=(Rotagivan/Models.swift Rotagivan/AppOverrides.swift Rotagivan/CursorResponse.swift Rotagivan/ScrollResponse.swift Rotagivan/TrackpadDistance.swift Rotagivan/SwipeDirectionClassification.swift)
for test in CursorResponseTests CursorGainTests CursorTelemetryTests ScrollResponseTests; do
  xcrun swiftc "${common[@]}" "Rotagivan/Tests/$test.swift" -o "$test_dir/$test"
  "$test_dir/$test"
done
for test in ProfileStorageTests ProfileActivationTests ShortcutRecorderTests; do
  xcrun swiftc "${common[@]}" Rotagivan/HotKeyManager.swift Rotagivan/ShortcutRecorder.swift \
    "Rotagivan/Tests/$test.swift" -framework AppKit -framework SwiftUI -framework Carbon -o "$test_dir/$test"
  "$test_dir/$test"
done
for test in ClickTests ParagraphSelectionTests; do
  xcrun swiftc "${common[@]}" Rotagivan/EventPoster.swift "Rotagivan/Tests/$test.swift" \
    -framework AppKit -framework CoreGraphics -o "$test_dir/$test"
  "$test_dir/$test"
done
xcrun swiftc Rotagivan/TrackpadReport.swift Rotagivan/Tests/ReportTests.swift -o "$test_dir/ReportTests"
"$test_dir/ReportTests"
xcrun swiftc Rotagivan/TrackpadDistance.swift Rotagivan/Tests/TrackpadDistanceTests.swift -o "$test_dir/TrackpadDistanceTests"
"$test_dir/TrackpadDistanceTests"
xcrun swiftc "${common[@]}" Rotagivan/TrackpadReport.swift Rotagivan/EventPoster.swift \
  Rotagivan/DoubleTapSwipe.swift Rotagivan/GestureEngine.swift Rotagivan/Tests/DoubleTapSwipeTests.swift \
  -framework AppKit -framework CoreGraphics -o "$test_dir/DoubleTapSwipeTests"
"$test_dir/DoubleTapSwipeTests"
xcrun swiftc "${common[@]}" Rotagivan/TrackpadReport.swift Rotagivan/EventPoster.swift \
  Rotagivan/DoubleTapSwipe.swift Rotagivan/GestureEngine.swift Rotagivan/Tests/TwoFingerTapSwipeTests.swift \
  -framework AppKit -framework CoreGraphics -o "$test_dir/TwoFingerTapSwipeTests"
"$test_dir/TwoFingerTapSwipeTests"
xcrun swiftc "${common[@]}" Rotagivan/TrackpadReport.swift Rotagivan/GestureCalibration.swift \
  Rotagivan/Tests/GestureCalibrationTests.swift -o "$test_dir/GestureCalibrationTests"
"$test_dir/GestureCalibrationTests"
xcrun swiftc "${common[@]}" Rotagivan/Tests/SwipeDirectionTests.swift -o "$test_dir/SwipeDirectionTests"
"$test_dir/SwipeDirectionTests"
xcrun swiftc "${common[@]}" Rotagivan/TrackpadReport.swift Rotagivan/AppExplorerSelection.swift \
  Rotagivan/Tests/AppExplorerTests.swift -o "$test_dir/AppExplorerTests"
"$test_dir/AppExplorerTests"
xcrun swiftc "${common[@]}" Rotagivan/ExplorerApplicationCatalog.swift Rotagivan/Tests/ExplorerApplicationCatalogTests.swift \
  -framework AppKit -o "$test_dir/ExplorerApplicationCatalogTests"
"$test_dir/ExplorerApplicationCatalogTests"
xcrun swiftc "${common[@]}" Rotagivan/WebsiteFavicon.swift Rotagivan/Tests/FaviconTests.swift \
  -framework AppKit -framework SwiftUI -o "$test_dir/FaviconTests"
"$test_dir/FaviconTests"
xcrun swiftc "${common[@]}" Rotagivan/WindowTiling.swift Rotagivan/Tests/WindowTilingTests.swift \
  -framework AppKit -framework SwiftUI -o "$test_dir/WindowTilingTests"
"$test_dir/WindowTilingTests"
xcrun swiftc "${common[@]}" Rotagivan/TrackpadReport.swift Rotagivan/DoubleTapSwipe.swift \
  Rotagivan/Tests/AppOverrideTests.swift -o "$test_dir/AppOverrideTests"
"$test_dir/AppOverrideTests"
xcrun swiftc "${common[@]}" Rotagivan/TrackpadReport.swift Rotagivan/EventPoster.swift \
  Rotagivan/DoubleTapSwipe.swift Rotagivan/GestureEngine.swift Rotagivan/Tests/TapActionTests.swift \
  -framework AppKit -framework CoreGraphics -o "$test_dir/TapActionTests"
"$test_dir/TapActionTests"
xcrun swiftc "${common[@]}" Rotagivan/TrackpadReport.swift Rotagivan/EventPoster.swift \
  Rotagivan/DoubleTapSwipe.swift Rotagivan/GestureEngine.swift Rotagivan/Tests/StationaryTapTests.swift \
  -framework AppKit -framework CoreGraphics -o "$test_dir/StationaryTapTests"
"$test_dir/StationaryTapTests"
xcrun swiftc "${common[@]}" Rotagivan/TrackpadReport.swift Rotagivan/EventPoster.swift \
  Rotagivan/DoubleTapSwipe.swift Rotagivan/GestureEngine.swift Rotagivan/Tests/ScrollResponseIntegrationTests.swift \
  -framework AppKit -framework CoreGraphics -o "$test_dir/ScrollResponseIntegrationTests"
"$test_dir/ScrollResponseIntegrationTests"
xcrun swiftc "${common[@]}" Rotagivan/TrackpadReport.swift Rotagivan/EventPoster.swift \
  Rotagivan/DoubleTapSwipe.swift Rotagivan/GestureEngine.swift Rotagivan/GestureCalibration.swift \
  Rotagivan/GestureCalibrationView.swift Rotagivan/AppExplorerSelection.swift Rotagivan/AppExplorer.swift \
  Rotagivan/HotKeyManager.swift Rotagivan/ShortcutRecorder.swift Rotagivan/AppExplorerSettingsView.swift \
  Rotagivan/ExplorerApplicationCatalog.swift Rotagivan/ExplorerDestinationPicker.swift \
  Rotagivan/WebsiteFavicon.swift \
  Rotagivan/WindowTiling.swift \
  Rotagivan/HIDManager.swift Rotagivan/Tests/CalibrationIntegrationTests.swift \
  -framework AppKit -framework SwiftUI -framework CoreGraphics -framework IOKit -framework Carbon -o "$test_dir/CalibrationIntegrationTests"
"$test_dir/CalibrationIntegrationTests"
xcrun swiftc -I "$yaml_build/Modules" -I YAML/.build/checkouts/Yams/Sources/CYaml/include \
  -L "$yaml_build" -lConfigurationYAML "${common[@]}" Rotagivan/HotKeyManager.swift \
  Rotagivan/AppConfiguration.swift Rotagivan/Tests/ConfigurationTests.swift \
  -framework AppKit -framework Carbon -o "$test_dir/ConfigurationTests"
"$test_dir/ConfigurationTests"
xcrun swiftc -I "$yaml_build/Modules" -I YAML/.build/checkouts/Yams/Sources/CYaml/include \
  -L "$yaml_build" -lConfigurationYAML "${common[@]}" Rotagivan/HotKeyManager.swift \
  Rotagivan/AppConfiguration.swift Rotagivan/SyncStorage.swift Rotagivan/Tests/SyncStorageTests.swift \
  -framework AppKit -framework Carbon -framework Security -o "$test_dir/SyncStorageTests"
"$test_dir/SyncStorageTests"
echo "All tests passed. Test binaries: $test_dir"
