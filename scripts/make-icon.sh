#!/usr/bin/env bash
# Regenerate the icon files from assets/icon.svg. Only needed when the icon changes;
# the build uses the committed files. Needs rsvg-convert (brew install librsvg).
#   assets/icon.png      1024 px, full bleed: the repo icon Slipway shows
#   assets/AppIcon.icns  the app icon, inside macOS's 100 px icon margin
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
rsvg-convert -w 1024 -h 1024 assets/icon.svg -o assets/icon.png
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
sed -e '1s|.*|<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024"><svg x="100" y="100" width="824" height="824" viewBox="0 0 1024 1024">|' \
    -e 's|^</svg>$|</svg></svg>|' assets/icon.svg > "$WORK/padded.svg"
mkdir "$WORK/AppIcon.iconset"
for size in 16 32 128 256 512; do
  rsvg-convert -w $size -h $size "$WORK/padded.svg" -o "$WORK/AppIcon.iconset/icon_${size}x${size}.png"
  rsvg-convert -w $((size * 2)) -h $((size * 2)) "$WORK/padded.svg" -o "$WORK/AppIcon.iconset/icon_${size}x${size}@2x.png"
done
iconutil -c icns "$WORK/AppIcon.iconset" -o assets/AppIcon.icns
echo 'Wrote assets/icon.png and assets/AppIcon.icns'
