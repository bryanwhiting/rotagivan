#!/bin/zsh
# Main-thread cost of common interactions on a synthetic, heavy configuration.
# Not part of test.sh; run it before and after a performance change.
# --only-chrome times tab activation against a running Chrome (it brings Chrome
# to the front); --only-macro times a three-chord macro without posting keys.
script_dir=${0:A:h}; cd "$script_dir/.."
test_dir=$(mktemp -d "${TMPDIR:-/private/tmp}/rota-ibench.XXXXXX")
yaml_build=$(swift build --package-path YAML -c release --show-bin-path)
settings_sources=()
while IFS= read -r source; do
  settings_sources+=("Rota/$source")
done < <(sed -n '/^sources=(/,/^)/s/^  "$script_dir\/\([^"]*\.swift\)"$/\1/p' Rota/build.sh | rg -v '^RotaApp.swift$')
xcrun swiftc -O -j 8 -I "$yaml_build/Modules" -I YAML/.build/checkouts/Yams/Sources/CYaml/include \
  -L "$yaml_build" -lConfigurationYAML -lsqlite3 "${settings_sources[@]}" Rota/Tests/InteractionBenchmark.swift \
  -framework AppKit -framework SwiftUI -framework AVFoundation -framework CoreGraphics -framework IOKit \
  -framework Carbon -framework Security -framework ServiceManagement -framework Speech -o "$test_dir/InteractionBenchmark" 2>&1 | grep -E "error" || true
"$test_dir/InteractionBenchmark" "$@"
