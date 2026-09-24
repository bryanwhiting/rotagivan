#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
cd "$script_dir"

npm run tauri build -- --bundles app
app_source="$script_dir/src-tauri/target/release/bundle/macos/Rota.app"
app_target="/Applications/Rota.app"

if [[ ! -d "$app_source" ]]; then
  print -u2 "Rota build not found at $app_source"
  exit 1
fi

osascript -e 'tell application "Rota" to quit' >/dev/null 2>&1 || true
for _ in {1..30}; do
  pgrep -x Rota >/dev/null || break
  sleep 0.1
done
ditto "$app_source" "$app_target"
open "$app_target"
print "Installed and launched $app_target"
