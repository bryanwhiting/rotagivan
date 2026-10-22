#!/bin/zsh
set -euo pipefail
script_dir=${0:A:h}
cd "$script_dir/.."
benchmark_dir=$(mktemp -d /private/tmp/rota-action-benchmark.XXXXXX)
common=(Rota/Models.swift Rota/AppOverrides.swift Rota/CursorResponse.swift
  Rota/ScrollResponse.swift Rota/TrackpadDistance.swift
  Rota/SwipeDirectionClassification.swift Rota/CredentialWorker.swift)
# Compile without the app, input managers, real settings, or live providers.
xcrun swiftc -O -j 4 "${common[@]}" Rota/HotkeyOrganizer.swift \
  Rota/ExplorerApplicationCatalog.swift Rota/SyncCrypto.swift Rota/VoiceActions.swift \
  Rota/ActionTableRow.swift Rota/ActionCatalogSnapshot.swift \
  Rota/HotKeyManager.swift Rota/ApplicationIndex.swift Rota/ApplicationIndexObservation.swift \
  Rota/Tests/ActionCatalogBenchmark.swift \
  -framework AppKit -framework Carbon -framework Security -o "$benchmark_dir/ActionCatalogBenchmark"
"$benchmark_dir/ActionCatalogBenchmark"
