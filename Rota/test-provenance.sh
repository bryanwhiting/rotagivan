#!/bin/zsh
set -euo pipefail
script_dir=${0:A:h}
python3 "$script_dir/Tests/test_build_provenance.py"
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/rota-provenance.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -j 4 -module-cache-path "$test_dir/modules" \
  "$script_dir/Models.swift" "$script_dir/AppOverrides.swift" "$script_dir/CursorResponse.swift" \
  "$script_dir/ScrollResponse.swift" "$script_dir/TrackpadDistance.swift" \
  "$script_dir/SwipeDirectionClassification.swift" "$script_dir/CredentialWorker.swift" \
  "$script_dir/Tests/AppVersionTests.swift" -framework Security -o "$test_dir/AppVersionTests"
"$test_dir/AppVersionTests" "$@"
