#!/usr/bin/env bash
# Build Dropshit.app from the ShelfDemo SwiftPM target, ad-hoc sign it,
# and package a DMG with an /Applications symlink.

set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="Dropshit"
BIN_NAME="ShelfDemo"
BUNDLE_ID="com.boski.dropshit"
VERSION="1.0"
BUILD="1"
MIN_OS="13.0"

APP_DIR="dist/${APP_NAME}.app"
DMG_ROOT="dist/dmgroot"
DMG_PATH="${APP_NAME}.dmg"

echo "==> Cleaning dist/"
rm -rf dist
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources"

echo "==> Regenerating AppIcon.icns"
ICONSET_TMP="$(mktemp -d)/AppIcon.iconset"
swift scripts/make-icon.swift "${ICONSET_TMP}"
iconutil -c icns -o "Sources/${BIN_NAME}/Resources/AppIcon.icns" "${ICONSET_TMP}"
rm -rf "${ICONSET_TMP%/*}"

echo "==> Building release binary"
swift build -c release

echo "==> Assembling .app bundle"
cp ".build/release/${BIN_NAME}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"
chmod +x "${APP_DIR}/Contents/MacOS/${APP_NAME}"

if [ -d "Sources/${BIN_NAME}/Resources" ]; then
  cp -R "Sources/${BIN_NAME}/Resources/." "${APP_DIR}/Contents/Resources/" 2>/dev/null || true
fi

cat > "${APP_DIR}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>${APP_NAME}</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>${APP_NAME}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD}</string>
  <key>LSMinimumSystemVersion</key><string>${MIN_OS}</string>
  <key>LSUIElement</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

echo "==> Ad-hoc signing"
codesign --force --deep --sign - "${APP_DIR}"
codesign --verify --verbose=2 "${APP_DIR}" || true

echo "==> Building DMG"
mkdir -p "${DMG_ROOT}"
cp -R "${APP_DIR}" "${DMG_ROOT}/${APP_NAME}.app"
ln -sfn /Applications "${DMG_ROOT}/Applications"

rm -f "${DMG_PATH}"
hdiutil create -volname "${APP_NAME}" -srcfolder "${DMG_ROOT}" -ov -format UDZO "${DMG_PATH}"

echo
echo "Done. Built: ${DMG_PATH}"
echo "First launch on a new machine (ad-hoc signed, not notarized):"
echo "  xattr -dr com.apple.quarantine /Applications/${APP_NAME}.app"
