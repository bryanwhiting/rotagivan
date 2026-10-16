#!/bin/zsh
set -euo pipefail
script_dir=${0:A:h}
cd "$script_dir/.."
test_dir=$(mktemp -d "${TMPDIR:-/private/tmp}/rotagivan-encrypted-sync.XXXXXX")
for name in EncryptedSettingsCore EncryptedPreferences EncryptedAutoSync; do
  sources=(Rotagivan/EncryptedSettingsCore.swift)
  [[ "$name" == EncryptedSettingsCore ]] || sources+=("Rotagivan/$name.swift")
  xcrun swiftc "${sources[@]}" "Rotagivan/Tests/${name}Tests.swift" -o "$test_dir/$name"
  "$test_dir/$name"
done
xcrun swiftc Rotagivan/EncryptedSettingsCore.swift Rotagivan/EncryptedPreferences.swift \
  Rotagivan/SettingsPersistence.swift Rotagivan/CredentialWorker.swift Rotagivan/Tests/SettingsPersistenceTests.swift \
  -framework AppKit -framework Security -o "$test_dir/SettingsPersistenceTests"
"$test_dir/SettingsPersistenceTests"
swift build --package-path YAML -c release --product ConfigurationYAML
yaml_build=$(swift build --package-path YAML -c release --show-bin-path)
common=(Rotagivan/Models.swift Rotagivan/AppOverrides.swift Rotagivan/CursorResponse.swift Rotagivan/ScrollResponse.swift Rotagivan/TrackpadDistance.swift Rotagivan/SwipeDirectionClassification.swift Rotagivan/CredentialWorker.swift)
xcrun swiftc -j 4 -I "$yaml_build/Modules" -I YAML/.build/checkouts/Yams/Sources/CYaml/include \
  -L "$yaml_build" -lConfigurationYAML "${common[@]}" Rotagivan/HotKeyManager.swift \
  Rotagivan/AppConfiguration.swift Rotagivan/SyncStorage.swift Rotagivan/EncryptedSettingsCore.swift \
  Rotagivan/SyncConfigurationCodec.swift Rotagivan/Tests/SyncCodecTests.swift \
  -framework AppKit -framework Carbon -framework Security -o "$test_dir/SyncCodecTests"
"$test_dir/SyncCodecTests"
sources=()
while IFS= read -r name; do
  sources+=("Rotagivan/$name")
done < <(sed -n 's/^  "$script_dir\/\(.*\.swift\)"$/\1/p' Rotagivan/build.sh | rg -v '^RotagivanApp.swift$')
xcrun swiftc -j 4 -parse-as-library -I "$yaml_build/Modules" -I "$yaml_build" -L "$yaml_build" -lConfigurationYAML \
  -I YAML/.build/checkouts/Yams/Sources/CYaml/include \
  -framework AppKit -framework CoreServices -framework AVFoundation -framework Speech \
  -framework SwiftUI -framework Carbon -framework IOKit -framework ServiceManagement -framework Security \
  "${sources[@]}" Rotagivan/Tests/AutomaticSyncIntegrationTests.swift -o "$test_dir/AutomaticSyncIntegrationTests"
"$test_dir/AutomaticSyncIntegrationTests" "$test_dir"
