#!/bin/zsh
# Builds the installer DMG: Reclaim on the left, an arrow, Applications on the right, on a branded background.
#   scripts/make_dmg.sh <Reclaim.app> <version> <out.dmg>
# Called by package.sh. Lays out the window through Finder, so the first run may ask to let Terminal control Finder.
set -euo pipefail
ROOT="${0:A:h:h}"
APP="${1:A}"
VERSION="$2"
OUT="${3:A}"
VOL="Reclaim $VERSION"
WORK="$(mktemp -d)"
MNT=""
trap '[[ -n "$MNT" ]] && hdiutil detach "$MNT" -force -quiet 2>/dev/null; rm -rf "$WORK"' EXIT

# Background at 1x and 2x, so it's sharp on Retina displays.
swiftc -O -o "$WORK/make_bg" -module-name ReclaimDMG \
  "$ROOT/scripts/make_dmg_background/main.swift" \
  "$ROOT/Reclaim/Core/Prefs.swift" \
  "$ROOT/Reclaim/Core/FileSystem.swift" \
  "$ROOT/Shared/Shared.swift"
"$WORK/make_bg" "$WORK/bg.png" 1
"$WORK/make_bg" "$WORK/bg@2x.png" 2
tiffutil -cathidpicheck "$WORK/bg.png" "$WORK/bg@2x.png" -out "$WORK/background.tiff" 2>/dev/null

# A writable image to lay out. Finder finds the window by volume name, so an older copy can't stay mounted.
[[ -d "/Volumes/$VOL" ]] && hdiutil detach "/Volumes/$VOL" -force -quiet
hdiutil create -size "$(( $(du -sm "$APP" | cut -f1) + 20 ))m" -fs HFS+ -volname "$VOL" "$WORK/rw.dmg" -quiet
MNT=$(hdiutil attach "$WORK/rw.dmg" -readwrite -noverify -noautoopen 2> >(grep -v "is deprecated" >&2) \
  | awk -F'\t' '/\/Volumes\// { print $NF }')

ditto "$APP" "$MNT/Reclaim.app"
ln -s /Applications "$MNT/Applications"
mkdir "$MNT/.background"
cp "$WORK/background.tiff" "$MNT/.background/background.tiff"
chflags hidden "$MNT/.background"
# The app icon as the volume icon.
cp "$APP/Contents/Resources/AppIcon.icns" "$MNT/.VolumeIcon.icns"
xcrun SetFile -a C "$MNT" 2>/dev/null || true

# Window layout; sizes and icon centres match scripts/make_dmg_background.
osascript <<EOF
tell application "Finder"
  tell disk "$VOL"
    open
    tell container window
      set current view to icon view
      set toolbar visible to false
      set statusbar visible to false
      set pathbar visible to false
      -- 640 x 400 of content plus the title bar.
      set bounds to {200, 120, 840, 552}
    end tell
    set opts to icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 128
    set text size of opts to 13
    set label position of opts to bottom
    set shows item info of opts to false
    set shows icon preview of opts to false
    set background picture of opts to file ".background:background.tiff"
    -- Out of view, for anyone whose Finder shows hidden files.
    set position of item ".background" to {320, 640}
    set position of item "Reclaim.app" to {170, 200}
    set position of item "Applications" to {470, 200}
    update without registering applications
    delay 1
    close
  end tell
end tell
EOF

# Wait for Finder to save the layout, then seal the image.
for _ in {1..20}; do [[ -f "$MNT/.DS_Store" ]] && break; sleep 0.5; done
rm -rf "$MNT/.fseventsd"
chmod -Rf go-w "$MNT" 2>/dev/null || true
sync
hdiutil detach "$MNT" -quiet
MNT=""
hdiutil convert "$WORK/rw.dmg" -format UDZO -imagekey zlib-level=9 -ov -o "$OUT" -quiet
