#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-release}"
APP_DIR="$ROOT_DIR/dist/QuotasWatcher.app"
LEGACY_APP_DIR="$ROOT_DIR/dist/QuotasWatch.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

swift build -c "$CONFIGURATION" --package-path "$ROOT_DIR"

rm -rf "$APP_DIR" "$LEGACY_APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$ROOT_DIR/.build/$CONFIGURATION/QuotasWatcher" "$MACOS_DIR/QuotasWatcher"
cp -R "$ROOT_DIR/Sources/QuotasWatcher/Resources/"*.lproj "$RESOURCES_DIR/"
printf "APPL????" > "$CONTENTS_DIR/PkgInfo"

cat > "$CONTENTS_DIR/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>QuotasWatcher</string>
  <key>CFBundleIdentifier</key>
  <string>com.local.QuotasWatcher</string>
  <key>CFBundleName</key>
  <string>QuotasWatcher</string>
  <key>CFBundleDisplayName</key>
  <string>QuotasWatcher</string>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleLocalizations</key>
  <array>
    <string>en</string>
    <string>zh-Hans</string>
  </array>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.2.1</string>
  <key>CFBundleVersion</key>
  <string>3</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

chmod +x "$MACOS_DIR/QuotasWatcher"
echo "Built $APP_DIR"
