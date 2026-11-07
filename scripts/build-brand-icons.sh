#!/usr/bin/env bash
# Convert the generated masters into macOS and web icon formats; preserves alpha.
set -euo pipefail
cd "$(dirname "$0")/.."
BRAND_WORK="$(mktemp -d)"
trap 'rm -rf "$BRAND_WORK"' EXIT
ICONSET="$BRAND_WORK/Retrace.iconset"
mkdir -p "$ICONSET" web/public/brand macos/Sources/Retrace/Resources

# Trim the master's clear outer margin so the menu-bar silhouette fills 18 points.
sips --cropToHeightWidth 920 920 assets/brand/retrace-mark-master.png --out "$BRAND_WORK/mark.png" >/dev/null
sips -z 128 128 "$BRAND_WORK/mark.png" --out web/public/brand/retrace-mark.png >/dev/null
sips -z 64 64 assets/brand/retrace-app-icon-master.png --out web/app/icon.png >/dev/null
sips -z 180 180 assets/brand/retrace-app-icon-master.png --out web/app/apple-icon.png >/dev/null
sips -z 18 18 "$BRAND_WORK/mark.png" --out macos/Sources/Retrace/Resources/RetraceMenuBarTemplate.png >/dev/null
sips -z 36 36 "$BRAND_WORK/mark.png" --out macos/Sources/Retrace/Resources/RetraceMenuBarTemplate@2x.png >/dev/null

for size in 16 32 128 256 512; do
  sips -z "$size" "$size" assets/brand/retrace-app-icon-master.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  retina=$((size * 2))
  sips -z "$retina" "$retina" assets/brand/retrace-app-icon-master.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o macos/Packaging/Retrace.icns
echo "Built macOS app/menu-bar icons and web brand/favicon assets."
