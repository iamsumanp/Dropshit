#!/usr/bin/env bash
# Build Dropshit.app from the ShelfDemo SwiftPM target, ad-hoc sign it,
# and package a DMG with an /Applications symlink.

set -euo pipefail

cd "$(dirname "$0")/.."

# Sparkle EdDSA public key — embedded in Info.plist as SUPublicEDKey.
# Generated once via the Sparkle generate_keys tool and stored in
# scripts/.sparkle-public-key (gitignored). The matching private key
# lives in the macOS Keychain on the release machine.
if [ -f scripts/.sparkle-public-key ]; then
  # shellcheck disable=SC1091
  source scripts/.sparkle-public-key
fi
if [ -z "${SPARKLE_PUBLIC_KEY:-}" ]; then
  echo "ERROR: SPARKLE_PUBLIC_KEY is not set."
  echo "Run the Sparkle generate_keys tool and write"
  echo "  SPARKLE_PUBLIC_KEY=<key>"
  echo "into scripts/.sparkle-public-key."
  exit 1
fi

# Sparkle appcast feed — raw GitHub URL on main.
SPARKLE_FEED_URL="https://raw.githubusercontent.com/iamsumanp/Dropshit/main/appcast.xml"

APP_NAME="Dropshit"
BIN_NAME="ShelfDemo"
BUNDLE_ID="com.boski.dropshit"
# VERSION drives both CFBundleShortVersionString and CFBundleVersion so the
# value Sparkle compares (sparkle:version vs CFBundleVersion) lines up with
# the same dotted form we publish in appcast.xml.
VERSION="1.5.0"
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

# Swift Package Manager builds a binary that doesn't know it'll live inside
# an .app bundle, so it doesn't add the standard Frameworks rpath. Without
# this, dyld can't find Sparkle.framework at runtime and the app won't launch.
install_name_tool -add_rpath @executable_path/../Frameworks "${APP_DIR}/Contents/MacOS/${APP_NAME}"

if [ -d "Sources/${BIN_NAME}/Resources" ]; then
  cp -R "Sources/${BIN_NAME}/Resources/." "${APP_DIR}/Contents/Resources/" 2>/dev/null || true
fi

echo "==> Embedding Sparkle.framework"
# The Sparkle xcframework artifact ships in .build/artifacts/ after `swift
# build` resolves the SPM dependency. Prefer the xcframework's macos slice
# (canonical, fully-signed by the Sparkle project) over a per-arch debug
# copy that swift build might leave under .build/<triple>/.
SPARKLE_FRAMEWORK_SRC=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [ ! -d "${SPARKLE_FRAMEWORK_SRC}" ]; then
  # Fall back to whatever swift build left behind.
  SPARKLE_FRAMEWORK_SRC="$(find .build -type d -name 'Sparkle.framework' -not -path '*xcframework*' | head -1)"
fi
if [ -z "${SPARKLE_FRAMEWORK_SRC}" ] || [ ! -d "${SPARKLE_FRAMEWORK_SRC}" ]; then
  echo "ERROR: Sparkle.framework not found under .build — run 'swift build -c release' first."
  exit 1
fi
mkdir -p "${APP_DIR}/Contents/Frameworks"
cp -R "${SPARKLE_FRAMEWORK_SRC}" "${APP_DIR}/Contents/Frameworks/"

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
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>${MIN_OS}</string>
  <key>LSUIElement</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>SUFeedURL</key><string>${SPARKLE_FEED_URL}</string>
  <key>SUPublicEDKey</key><string>${SPARKLE_PUBLIC_KEY}</string>
  <key>SUEnableInstallerLauncherService</key><false/>
</dict>
</plist>
PLIST

echo "==> Ad-hoc signing (inner-out)"
SPARKLE_FX="${APP_DIR}/Contents/Frameworks/Sparkle.framework"
# Sparkle 2.x framework contains XPC services and helper apps that must each
# be signed before the outer framework is sealed. `codesign --deep` does the
# right thing for ad-hoc signing because we don't have an entitlement profile
# that varies per nested binary.
codesign --force --deep --sign - "${SPARKLE_FX}/Versions/Current/XPCServices/Installer.xpc" 2>/dev/null || true
codesign --force --deep --sign - "${SPARKLE_FX}/Versions/Current/XPCServices/Downloader.xpc" 2>/dev/null || true
codesign --force --deep --sign - "${SPARKLE_FX}/Versions/Current/Updater.app" 2>/dev/null || true
codesign --force --deep --sign - "${SPARKLE_FX}/Versions/Current/Autoupdate" 2>/dev/null || true
codesign --force --deep --sign - "${SPARKLE_FX}"
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
