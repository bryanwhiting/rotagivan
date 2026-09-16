#!/bin/zsh
set -euo pipefail
script_dir=${0:A:h}
cd "$script_dir/.."
test_dir=$(mktemp -d /private/tmp/rotagivan-tests.XXXXXX)
swift build --package-path YAML -c release --product ConfigurationYAML
yaml_build=$(swift build --package-path YAML -c release --show-bin-path)
common=(Rotagivan/Models.swift Rotagivan/CursorResponse.swift)
for test in CursorResponseTests CursorGainTests CursorTelemetryTests; do
  xcrun swiftc "${common[@]}" "Rotagivan/Tests/$test.swift" -o "$test_dir/$test"
  "$test_dir/$test"
done
for test in ProfileStorageTests ProfileActivationTests ShortcutRecorderTests; do
  xcrun swiftc "${common[@]}" Rotagivan/HotKeyManager.swift Rotagivan/ShortcutRecorder.swift \
    "Rotagivan/Tests/$test.swift" -framework AppKit -framework SwiftUI -framework Carbon -o "$test_dir/$test"
  "$test_dir/$test"
done
xcrun swiftc "${common[@]}" Rotagivan/EventPoster.swift Rotagivan/Tests/ClickTests.swift \
  -framework AppKit -framework CoreGraphics -o "$test_dir/ClickTests"
"$test_dir/ClickTests"
xcrun swiftc Rotagivan/TrackpadReport.swift Rotagivan/Tests/ReportTests.swift -o "$test_dir/ReportTests"
"$test_dir/ReportTests"
xcrun swiftc -I "$yaml_build/Modules" -I YAML/.build/checkouts/Yams/Sources/CYaml/include \
  -L "$yaml_build" -lConfigurationYAML "${common[@]}" Rotagivan/HotKeyManager.swift \
  Rotagivan/AppConfiguration.swift Rotagivan/Tests/ConfigurationTests.swift \
  -framework AppKit -framework Carbon -o "$test_dir/ConfigurationTests"
"$test_dir/ConfigurationTests"
echo "All tests passed. Test binaries: $test_dir"
