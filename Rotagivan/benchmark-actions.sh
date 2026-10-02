#!/bin/zsh
set -euo pipefail
script_dir=${0:A:h}
cd "$script_dir/.."
benchmark_dir=$(mktemp -d /private/tmp/rotagivan-action-benchmark.XXXXXX)
common=(Rotagivan/Models.swift Rotagivan/AppOverrides.swift Rotagivan/CursorResponse.swift
  Rotagivan/ScrollResponse.swift Rotagivan/TrackpadDistance.swift
  Rotagivan/SwipeDirectionClassification.swift Rotagivan/CredentialWorker.swift)
# Compile without the app, input managers, real settings, or live providers.
xcrun swiftc -O -j 4 "${common[@]}" Rotagivan/HotkeyOrganizer.swift \
  Rotagivan/ExplorerApplicationCatalog.swift Rotagivan/VaultCrypto.swift Rotagivan/VoiceActions.swift \
  Rotagivan/ActionTableRow.swift Rotagivan/ActionCatalogSnapshot.swift \
  Rotagivan/HotKeyManager.swift Rotagivan/ApplicationIndex.swift Rotagivan/ApplicationIndexObservation.swift \
  Rotagivan/Tests/ActionCatalogBenchmark.swift \
  -framework AppKit -framework Carbon -framework Security -o "$benchmark_dir/ActionCatalogBenchmark"
"$benchmark_dir/ActionCatalogBenchmark"
