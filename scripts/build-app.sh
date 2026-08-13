#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="release"
APP_NAME="StickyNotes"
APP_DIR="build/${APP_NAME}.app"
EXEC_NAME="StickyNotes"

echo "==> swift build -c ${CONFIG}"
swift build -c "${CONFIG}"

BIN_PATH="$(swift build -c "${CONFIG}" --show-bin-path)/${EXEC_NAME}"
if [ ! -x "${BIN_PATH}" ]; then
    echo "Build artifact not found at ${BIN_PATH}" >&2
    exit 1
fi

echo "==> assembling ${APP_DIR}"
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

cp "${BIN_PATH}" "${APP_DIR}/Contents/MacOS/${EXEC_NAME}"
cp Resources/Info.plist "${APP_DIR}/Contents/Info.plist"

# Substitute the version placeholder in the copied Info.plist. Pass VERSION
# explicitly (e.g. release.sh does this) or fall back to the latest git tag.
APP_VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')}"
APP_VERSION="${APP_VERSION:-0.0.0-dev}"
sed -i '' "s|__APP_VERSION__|${APP_VERSION}|g" "${APP_DIR}/Contents/Info.plist"

# Generate icons on demand if missing.
if [ ! -f Resources/AppIcon.icns ]; then
    ./scripts/generate-icon.sh
fi

cp Resources/AppIcon.icns "${APP_DIR}/Contents/Resources/AppIcon.icns"
cp Resources/MenuBarIcon.png "${APP_DIR}/Contents/Resources/MenuBarIcon.png"
cp Resources/MenuBarIcon@2x.png "${APP_DIR}/Contents/Resources/MenuBarIcon@2x.png"

# Signing.
#
# With a Developer ID identity in SIGN_IDENTITY the app is signed properly and,
# when notarization credentials are also present, submitted to Apple. Without
# them we fall back to ad-hoc signing, which still runs but leaves macOS
# showing the "unidentified developer" block on first launch.
#
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
#   NOTARY_PROFILE=notary-profile   # from: xcrun notarytool store-credentials
if [ -n "${SIGN_IDENTITY:-}" ]; then
    echo "==> signing with ${SIGN_IDENTITY}"
    codesign --force --deep --options runtime --timestamp \
             --sign "${SIGN_IDENTITY}" "${APP_DIR}"

    if [ -n "${NOTARY_PROFILE:-}" ]; then
        ZIP_PATH="build/${APP_NAME}.zip"
        echo "==> notarizing (waits on Apple, usually a few minutes)"
        ditto -c -k --keepParent "${APP_DIR}" "${ZIP_PATH}"
        xcrun notarytool submit "${ZIP_PATH}" \
              --keychain-profile "${NOTARY_PROFILE}" --wait
        # Staple so the app validates without a network round trip.
        xcrun stapler staple "${APP_DIR}"
        rm -f "${ZIP_PATH}"
        echo "==> notarized and stapled"
    else
        echo "==> signed but not notarized (set NOTARY_PROFILE to notarize)"
    fi
else
    echo "==> ad-hoc signing (set SIGN_IDENTITY for a distributable build)"
    codesign --force --deep --sign - "${APP_DIR}" >/dev/null 2>&1 || true
fi

echo "==> done: ${APP_DIR}"
echo
echo "Run with: open ${APP_DIR}"
echo "Install:  cp -R ${APP_DIR} /Applications/"
