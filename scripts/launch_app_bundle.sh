#!/usr/bin/env bash
set -euo pipefail

APP_NAME="ChampollionDeckApp"
EXECUTABLE_PATH=".build/arm64-apple-macosx/debug/${APP_NAME}"
BUNDLE_DIR=".build/AppBundle/${APP_NAME}.app"
MACOS_DIR="${BUNDLE_DIR}/Contents/MacOS"
INFO_PLIST="${BUNDLE_DIR}/Contents/Info.plist"
XCODE_DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"

if [[ -d "${XCODE_DEVELOPER_DIR}" ]]; then
  echo "Building with Xcode toolchain..."
  DEVELOPER_DIR="${XCODE_DEVELOPER_DIR}" swift build
else
  echo "warning: Xcode not found at ${XCODE_DEVELOPER_DIR}; using current toolchain."
  swift build
fi

if [[ ! -x "${EXECUTABLE_PATH}" ]]; then
  echo "error: executable not found after build: ${EXECUTABLE_PATH}"
  exit 1
fi

mkdir -p "${MACOS_DIR}"
cp "${EXECUTABLE_PATH}" "${MACOS_DIR}/${APP_NAME}"
chmod +x "${MACOS_DIR}/${APP_NAME}"

cat > "${INFO_PLIST}" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>ChampollionDeckApp</string>
  <key>CFBundleIdentifier</key>
  <string>com.ttrace.champolliondeck</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>ChampollionDeckApp</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

echo "Created app bundle: ${BUNDLE_DIR}"
open "${BUNDLE_DIR}"
