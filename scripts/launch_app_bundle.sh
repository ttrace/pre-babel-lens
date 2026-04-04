#!/usr/bin/env bash
set -euo pipefail

APP_NAME="PreBabelLens"
EXECUTABLE_PATH=".build/arm64-apple-macosx/debug/${APP_NAME}"
BUNDLE_DIR=".build/AppBundle/${APP_NAME}.app"
MACOS_DIR="${BUNDLE_DIR}/Contents/MacOS"
RESOURCES_DIR="${BUNDLE_DIR}/Contents/Resources"
INFO_PLIST="${BUNDLE_DIR}/Contents/Info.plist"
LOCALIZATION_SOURCE_DIR="Localizations"
ICON_FILE_SOURCE="Assets/AppIcon.icns"
ICON_FILE_NAME="AppIcon.icns"
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
mkdir -p "${RESOURCES_DIR}"
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
  <string>PreBabelLens</string>
  <key>CFBundleIdentifier</key>
  <string>com.ttrace.prebabellens</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>PreBabelLens</string>
  <key>CFBundleDisplayName</key>
  <string>Pre-Babel Lens</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key>
      <string>com.ttrace.prebabellens.url</string>
      <key>CFBundleURLSchemes</key>
      <array>
        <string>prebabellens</string>
      </array>
    </dict>
  </array>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.2.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>26.0</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>CFBundleLocalizations</key>
  <array>
    <string>en</string>
    <string>ja</string>
  </array>
</dict>
</plist>
PLIST

if [[ -d "${LOCALIZATION_SOURCE_DIR}" ]]; then
  cp -R "${LOCALIZATION_SOURCE_DIR}/"*.lproj "${RESOURCES_DIR}/" 2>/dev/null || true
fi

if [[ -f "${ICON_FILE_SOURCE}" ]]; then
  cp "${ICON_FILE_SOURCE}" "${RESOURCES_DIR}/${ICON_FILE_NAME}"
fi

echo "Created app bundle: ${BUNDLE_DIR}"
open "${BUNDLE_DIR}"
