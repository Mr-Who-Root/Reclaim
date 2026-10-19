#!/bin/zsh
# Regenerates Reclaim/Assets.xcassets/AppIcon.appiconset from IconRenderer.swift.
set -euo pipefail
ROOT="${0:A:h:h}"
BIN="$(mktemp -d)/make_icon"
swiftc -O -o "$BIN" -module-name ReclaimIcon \
  "$ROOT/scripts/make_icon/main.swift" \
  "$ROOT/Reclaim/Core/IconRenderer.swift" \
  "$ROOT/Reclaim/Core/Prefs.swift" \
  "$ROOT/Reclaim/Core/FileSystem.swift" \
  "$ROOT/Shared/Shared.swift"
"$BIN" "$ROOT/Reclaim/Assets.xcassets/AppIcon.appiconset"
