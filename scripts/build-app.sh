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

# Ad-hoc sign so macOS Gatekeeper at least accepts it after the user grants permission.
codesign --force --deep --sign - "${APP_DIR}" >/dev/null 2>&1 || true

echo "==> done: ${APP_DIR}"
echo
echo "Run with: open ${APP_DIR}"
echo "Install:  cp -R ${APP_DIR} /Applications/"
