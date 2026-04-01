#!/usr/bin/env bash
set -euo pipefail

APP_NAME="PreBabelLens"
BUNDLE_ID="com.ttrace.prebabellens"
VERSION="${VERSION:-0.6.3}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
APPLE_ID="${APPLE_ID:-}"
APPLE_TEAM_ID="${APPLE_TEAM_ID:-}"
# Backward-compat: allow APPLE_PASSWORD as an alias of APPLE_APP_SPECIFIC_PASSWORD.
APPLE_APP_SPECIFIC_PASSWORD="${APPLE_APP_SPECIFIC_PASSWORD:-${APPLE_PASSWORD:-}}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"

XCODE_DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
BUILD_OUTPUT_DIR=".build/arm64-apple-macosx/release"
EXECUTABLE_PATH="${BUILD_OUTPUT_DIR}/${APP_NAME}"
ARTIFACTS_DIR="dist/releases/v${VERSION}"
BUNDLE_DIR="${ARTIFACTS_DIR}/${APP_NAME}.app"
MACOS_DIR="${BUNDLE_DIR}/Contents/MacOS"
RESOURCES_DIR="${BUNDLE_DIR}/Contents/Resources"
ZIP_PATH="${ARTIFACTS_DIR}/${APP_NAME}-v${VERSION}.zip"
DMG_STAGING_DIR="${ARTIFACTS_DIR}/${APP_NAME}-dmg"
DMG_PATH="${ARTIFACTS_DIR}/${APP_NAME}-v${VERSION}.dmg"

mkdir -p "${ARTIFACTS_DIR}"
rm -rf "${BUNDLE_DIR}" "${ZIP_PATH}" "${DMG_STAGING_DIR}" "${DMG_PATH}"

if [[ -d "${XCODE_DEVELOPER_DIR}" ]]; then
  echo "Building release with Xcode toolchain..."
  DEVELOPER_DIR="${XCODE_DEVELOPER_DIR}" swift build -c release
else
  echo "warning: Xcode not found at ${XCODE_DEVELOPER_DIR}; using current toolchain."
  swift build -c release
fi

if [[ ! -x "${EXECUTABLE_PATH}" ]]; then
  echo "error: executable not found after release build: ${EXECUTABLE_PATH}"
  exit 1
fi

mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"
cp "${EXECUTABLE_PATH}" "${MACOS_DIR}/${APP_NAME}"
chmod +x "${MACOS_DIR}/${APP_NAME}"

cat > "${BUNDLE_DIR}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key>
  <string>${BUNDLE_ID}</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key>
  <string>Pre-Babel Lens</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key>
      <string>${BUNDLE_ID}.url</string>
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
  <string>${VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${BUILD_NUMBER}</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
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

if [[ -d "Localizations" ]]; then
  cp -R Localizations/*.lproj "${RESOURCES_DIR}/" 2>/dev/null || true
fi
if [[ -f "Assets/AppIcon.icns" ]]; then
  cp "Assets/AppIcon.icns" "${RESOURCES_DIR}/AppIcon.icns"
fi

if [[ -z "${SIGN_IDENTITY}" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning | awk -F\" '/Developer ID Application:/ {print $2; exit}')"
fi

if [[ -z "${SIGN_IDENTITY}" ]]; then
  echo "error: no Developer ID Application identity found."
  exit 1
fi

echo "Signing app with identity: ${SIGN_IDENTITY}"
codesign --force --deep --options runtime --timestamp --sign "${SIGN_IDENTITY}" "${BUNDLE_DIR}"
codesign --verify --deep --strict --verbose=2 "${BUNDLE_DIR}"

echo "Creating upload zip..."
ditto -c -k --sequesterRsrc --keepParent "${BUNDLE_DIR}" "${ZIP_PATH}"

echo "Preparing DMG contents..."
mkdir -p "${DMG_STAGING_DIR}"
cp -R "${BUNDLE_DIR}" "${DMG_STAGING_DIR}/${APP_NAME}.app"

if command -v osascript >/dev/null 2>&1; then
  if ! osascript \
    -e 'tell application "Finder"' \
    -e 'set targetFolder to POSIX file "/Applications"' \
    -e 'set destinationFolder to POSIX file "'"${DMG_STAGING_DIR}"'"' \
    -e 'if not (exists alias file "Applications" of folder destinationFolder) then make new alias file at folder destinationFolder to targetFolder with properties {name:"Applications"}' \
    -e 'end tell'
  then
    ln -s /Applications "${DMG_STAGING_DIR}/Applications"
  fi
else
  ln -s /Applications "${DMG_STAGING_DIR}/Applications"
fi

echo "Creating DMG..."
hdiutil create \
  -volname "Pre-Babel Lens" \
  -srcfolder "${DMG_STAGING_DIR}" \
  -ov \
  -format UDZO \
  "${DMG_PATH}"

echo "Submitting to notarization..."
if [[ -n "${NOTARY_PROFILE}" ]]; then
  xcrun notarytool submit "${ZIP_PATH}" --keychain-profile "${NOTARY_PROFILE}" --wait
  xcrun notarytool submit "${DMG_PATH}" --keychain-profile "${NOTARY_PROFILE}" --wait
elif [[ -n "${APPLE_ID}" && -n "${APPLE_TEAM_ID}" && -n "${APPLE_APP_SPECIFIC_PASSWORD}" ]]; then
  xcrun notarytool submit "${ZIP_PATH}" \
    --apple-id "${APPLE_ID}" \
    --team-id "${APPLE_TEAM_ID}" \
    --password "${APPLE_APP_SPECIFIC_PASSWORD}" \
    --wait
  xcrun notarytool submit "${DMG_PATH}" \
    --apple-id "${APPLE_ID}" \
    --team-id "${APPLE_TEAM_ID}" \
    --password "${APPLE_APP_SPECIFIC_PASSWORD}" \
    --wait
else
  echo "error: notarization credentials are missing."
  echo "Set NOTARY_PROFILE or APPLE_ID + APPLE_TEAM_ID + APPLE_APP_SPECIFIC_PASSWORD."
  exit 1
fi

echo "Stapling notarization ticket..."
xcrun stapler staple "${BUNDLE_DIR}"
xcrun stapler validate "${BUNDLE_DIR}"
xcrun stapler staple "${DMG_PATH}"
xcrun stapler validate "${DMG_PATH}"

echo "Release artifact ready:"
echo "  App: ${BUNDLE_DIR}"
echo "  Zip: ${ZIP_PATH}"
echo "  DMG: ${DMG_PATH}"
