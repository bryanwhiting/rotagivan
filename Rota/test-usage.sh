#!/bin/bash
set -euo pipefail
script_dir="$(cd "$(dirname "$0")" && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/rota-usage.XXXXXX")"
trap 'rm -f "$test_dir/usage-tests" "$test_dir/instrumentation-tests"; rmdir "$test_dir"' EXIT
xcrun swiftc "$script_dir/LocalUsageCore.swift" "$script_dir/Tests/LocalUsageTests.swift" -o "$test_dir/usage-tests"
"$test_dir/usage-tests"
xcrun swiftc "$script_dir/Models.swift" "$script_dir/AppOverrides.swift" "$script_dir/CursorResponse.swift" \
  "$script_dir/ScrollResponse.swift" "$script_dir/TrackpadDistance.swift" "$script_dir/SwipeDirectionClassification.swift" \
  "$script_dir/CredentialWorker.swift" "$script_dir/EventPoster.swift" "$script_dir/MacroPlayback.swift" \
  "$script_dir/Tests/ActionUsageInstrumentationTests.swift" -framework AppKit -framework Security -o "$test_dir/instrumentation-tests"
"$test_dir/instrumentation-tests"
