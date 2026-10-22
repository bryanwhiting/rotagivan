#!/bin/zsh
# Point this clone at the versioned hooks in scripts/githooks (one-time per clone).
set -euo pipefail
repo=${0:A:h:h}
chmod +x "$repo"/scripts/githooks/*
git -C "$repo" config core.hooksPath scripts/githooks
print -- "core.hooksPath = scripts/githooks ($(ls "$repo/scripts/githooks" | tr '\n' ' '))"
