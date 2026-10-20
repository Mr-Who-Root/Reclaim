#!/bin/zsh
# Builds Reclaim (Release, universal) and packages build/Reclaim-<version>.dmg and .zip for a GitHub release.
set -euo pipefail
ROOT="${0:A:h:h}"
cd "$ROOT"
source scripts/signing.sh

xcodebuild -project Reclaim.xcodeproj -scheme Reclaim -configuration Release \
  -derivedDataPath .build/release ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO "${SIGN_ARGS[@]}" build \
  | grep -E "error:|BUILD (SUCCEEDED|FAILED)" || true

APP=".build/release/Build/Products/Release/Reclaim.app"
[[ -d "$APP" ]] || { echo "Build failed"; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")

mkdir -p build
rm -rf build/Reclaim.app "build/Reclaim-$VERSION.dmg" "build/Reclaim-$VERSION.zip"
cp -R "$APP" build/Reclaim.app
codesign --verify --deep --strict build/Reclaim.app

# Zip (keeps the bundle's symlinks and signature intact).
ditto -c -k --keepParent build/Reclaim.app "build/Reclaim-$VERSION.zip"

# DMG with a drag-to-Applications layout.
scripts/make_dmg.sh build/Reclaim.app "$VERSION" "build/Reclaim-$VERSION.dmg"

shasum -a 256 "build/Reclaim-$VERSION.dmg" "build/Reclaim-$VERSION.zip"
echo "Packaged build/Reclaim-$VERSION.dmg and build/Reclaim-$VERSION.zip"
