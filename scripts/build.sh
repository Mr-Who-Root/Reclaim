#!/bin/zsh
# Builds Reclaim (Release) and, with --install, copies it to /Applications and opens it.
#   scripts/build.sh            # build only → build/Release/Reclaim.app
#   scripts/build.sh --install  # build, install to /Applications, launch
set -euo pipefail
ROOT="${0:A:h:h}"
cd "$ROOT"
source scripts/signing.sh

xcodebuild -project Reclaim.xcodeproj -scheme Reclaim -configuration Release \
  -derivedDataPath .build/release "${SIGN_ARGS[@]}" build | grep -E "error:|warning: .*Reclaim/|BUILD (SUCCEEDED|FAILED)" || true

APP=".build/release/Build/Products/Release/Reclaim.app"
[[ -d "$APP" ]] || { echo "Build failed"; exit 1; }
mkdir -p build && rm -rf build/Reclaim.app && cp -R "$APP" build/Reclaim.app
echo "Built $ROOT/build/Reclaim.app"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x Reclaim 2>/dev/null && sleep 1 || true
  rm -rf /Applications/Reclaim.app
  cp -R build/Reclaim.app /Applications/Reclaim.app
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Reclaim.app
  open /Applications/Reclaim.app
  echo "Installed /Applications/Reclaim.app"
fi
