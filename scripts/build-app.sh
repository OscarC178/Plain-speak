#!/usr/bin/env bash
# Build Plainspeak.app: the Swift menu bar app, the compiled service, Claude's own
# binary, the panel and settings pages, and the icon.
#
#   bash scripts/build-app.sh            # build into build/Plainspeak.app
#   bash scripts/build-app.sh --install  # build, then replace /Applications/Plainspeak.app and open it
#
# Signing: PLAINSPEAK_SIGN_IDENTITY, else the first code-signing identity in your
# keychain. A stable identity lets macOS keep the Accessibility and Screen Recording
# permissions across rebuilds; ad-hoc signing (no identity) asks again each build.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$HOME/.bun/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
cd "$ROOT"
for tool in bun swift rsvg-convert iconutil codesign; do
  command -v "$tool" >/dev/null || { echo "Missing $tool. See \"Build the app\" in the README." >&2; exit 1; }
done

APP="$ROOT/build/Plainspeak.app"; C="$APP/Contents"; R="$C/Resources"
VERSION="$(bun -e 'console.log(require("./package.json").version)')"
rm -rf "$APP"
mkdir -p "$C/MacOS" "$R/service/src"
[[ -d node_modules/@anthropic-ai/claude-agent-sdk ]] || bun install --frozen-lockfile

echo '1/5 Swift app'
# SwiftPM's newer build system fails with only the Command Line Tools installed
# ("Unknown error parsing property list"), so use the original one until it works.
SWIFT=(swift build -c release --package-path app --build-system native)
"${SWIFT[@]}" 2>&1 | grep -v "has been deprecated" || true
[[ -x "$("${SWIFT[@]}" --show-bin-path 2>/dev/null)/Plainspeak" ]] || { echo 'Swift build failed.' >&2; exit 1; }
cp "$("${SWIFT[@]}" --show-bin-path 2>/dev/null)/Plainspeak" "$C/MacOS/Plainspeak"

echo '2/5 Service and Claude'
bun build --compile --minify src/main.ts --outfile "$R/plainspeak-service"
# Claude's binary ships unmodified, with Anthropic's own signature.
cp node_modules/@anthropic-ai/claude-agent-sdk-darwin-arm64/claude "$R/claude"
cp src/overlay.html src/settings.html "$R/service/src/"

echo '3/5 Icon'
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
# macOS app icons sit inside a 1024 px canvas with a 100 px margin.
sed -e '1s|.*|<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024"><svg x="100" y="100" width="824" height="824" viewBox="0 0 1024 1024">|' \
    -e 's|^</svg>$|</svg></svg>|' assets/icon.svg > "$WORK/padded.svg"
mkdir "$WORK/AppIcon.iconset"
for size in 16 32 128 256 512; do
  rsvg-convert -w $size -h $size "$WORK/padded.svg" -o "$WORK/AppIcon.iconset/icon_${size}x${size}.png"
  rsvg-convert -w $((size * 2)) -h $((size * 2)) "$WORK/padded.svg" -o "$WORK/AppIcon.iconset/icon_${size}x${size}@2x.png"
done
iconutil -c icns "$WORK/AppIcon.iconset" -o "$R/AppIcon.icns"

echo '4/5 Info.plist'
cat > "$C/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.oscarc.plainspeak</string>
  <key>CFBundleName</key><string>Plainspeak</string>
  <key>CFBundleDisplayName</key><string>Plainspeak</string>
  <key>CFBundleExecutable</key><string>Plainspeak</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$(date +%Y%m%d%H%M)</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <!-- The panel and captures talk to the service on 127.0.0.1 over plain http. -->
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
PLIST
plutil -lint -s "$C/Info.plist"

echo '5/5 Sign'
IDENTITY="${PLAINSPEAK_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(.*\)"$/\1/p' | head -1)}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY='-'
  echo 'No signing identity found: signing ad hoc. macOS will ask for permissions again after each build.'
fi
codesign --force --sign "$IDENTITY" "$R/plainspeak-service"
codesign --force --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"
echo "Built $APP ($(du -sh "$APP" | cut -f1), signed with: $IDENTITY)"

if [[ "${1:-}" == "--install" ]]; then
  osascript -e 'quit app "Plainspeak"' 2>/dev/null || true
  sleep 1
  rm -rf /Applications/Plainspeak.app
  ditto "$APP" /Applications/Plainspeak.app
  open /Applications/Plainspeak.app
  echo 'Installed and opened /Applications/Plainspeak.app'
fi
