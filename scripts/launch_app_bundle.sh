#!/usr/bin/env bash
set -euo pipefail

APP_NAME="PreBabelLens"
SHOULD_OPEN_APP=1
APPLE_LANGUAGE=""
APPLE_LOCALE=""
EXECUTABLE_PATH=".build/arm64-apple-macosx/debug/${APP_NAME}"
BUNDLE_DIR=".build/AppBundle/${APP_NAME}.app"
MACOS_DIR="${BUNDLE_DIR}/Contents/MacOS"
RESOURCES_DIR="${BUNDLE_DIR}/Contents/Resources"
INFO_PLIST="${BUNDLE_DIR}/Contents/Info.plist"
LOCALIZATION_SOURCE_DIR="Localizations"
ICON_FILE_SOURCE="Assets/AppIcon.icns"
ICON_FILE_NAME="AppIcon.icns"
XCODE_DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"

usage() {
  cat <<'USAGE'
Usage: scripts/launch_app_bundle.sh [options]

Options:
  --no-open           Build bundle only (do not launch app)
  --lang <code>       Launch with AppleLanguages (e.g. en, ja, ko, zh-Hans, zh-Hant)
  --locale <code>     Launch with AppleLocale (e.g. en_US, ja_JP, ko_KR, zh_CN, zh_TW)
  --help              Show this help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-open)
      SHOULD_OPEN_APP=0
      shift
      ;;
    --lang)
      if [[ $# -lt 2 ]]; then
        echo "error: --lang requires a value"
        exit 1
      fi
      APPLE_LANGUAGE="$2"
      shift 2
      ;;
    --locale)
      if [[ $# -lt 2 ]]; then
        echo "error: --locale requires a value"
        exit 1
      fi
      APPLE_LOCALE="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

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
    <string>ko</string>
    <string>zh-Hans</string>
    <string>zh-Hant</string>
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
if [[ "${SHOULD_OPEN_APP}" == "1" ]]; then
  OPEN_ARGS=()
  if [[ -n "${APPLE_LANGUAGE}" ]]; then
    OPEN_ARGS+=("-AppleLanguages" "(${APPLE_LANGUAGE})")
  fi
  if [[ -n "${APPLE_LOCALE}" ]]; then
    OPEN_ARGS+=("-AppleLocale" "${APPLE_LOCALE}")
  fi

  if [[ ${#OPEN_ARGS[@]} -gt 0 ]]; then
    echo "Launching with runtime args: ${OPEN_ARGS[*]}"
    open "${BUNDLE_DIR}" --args "${OPEN_ARGS[@]}"
  else
    open "${BUNDLE_DIR}"
  fi
fi
