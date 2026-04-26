#!/usr/bin/env bash
set -euo pipefail

# Build StickyNotes.app, package it into a drag-to-Applications .dmg
# (and a fallback .zip), and publish a GitHub release with both assets.
#
# Usage: scripts/release.sh <version> [release-notes-file]
#   scripts/release.sh v0.3.0
#   scripts/release.sh v0.3.0 RELEASE_NOTES.md

if [ "$#" -lt 1 ]; then
    echo "Usage: $0 <version> [notes-file]" >&2
    echo "       $0 v0.3.0" >&2
    exit 1
fi

VERSION="$1"
NOTES_FILE="${2:-}"

cd "$(dirname "$0")/.."

APP_NAME="StickyNotes"
APP_DIR="build/${APP_NAME}.app"
DMG_NAME="${APP_NAME}-${VERSION}.dmg"
ZIP_NAME="${APP_NAME}-${VERSION}.zip"
DMG_STAGING="build/dmg-staging"

# 1. Build the .app via the existing helper.
echo "==> building ${APP_DIR}"
./scripts/build-app.sh

# 2. Stage the .app + a /Applications symlink so the DMG window shows the
#    classic "drag StickyNotes here" install experience.
echo "==> staging DMG contents"
rm -rf "${DMG_STAGING}"
mkdir -p "${DMG_STAGING}"
cp -R "${APP_DIR}" "${DMG_STAGING}/"
ln -s /Applications "${DMG_STAGING}/Applications"

# 3. Create the DMG (compressed).
echo "==> creating ${DMG_NAME}"
rm -f "build/${DMG_NAME}"
hdiutil create \
    -volname "${APP_NAME}" \
    -srcfolder "${DMG_STAGING}" \
    -ov \
    -format UDZO \
    "build/${DMG_NAME}" >/dev/null

# 4. Also produce a plain .zip for users who prefer it.
echo "==> creating ${ZIP_NAME}"
rm -f "build/${ZIP_NAME}"
( cd build && zip -ry "${ZIP_NAME}" "${APP_NAME}.app" >/dev/null )

# 5. Tag + release on GitHub.
echo "==> publishing GitHub release ${VERSION}"
NOTES_ARGS=()
if [ -n "${NOTES_FILE}" ] && [ -f "${NOTES_FILE}" ]; then
    NOTES_ARGS=(--notes-file "${NOTES_FILE}")
else
    NOTES_ARGS=(--generate-notes)
fi

if gh release view "${VERSION}" >/dev/null 2>&1; then
    echo "    release ${VERSION} already exists — uploading assets (overwriting)"
    gh release upload "${VERSION}" "build/${DMG_NAME}" "build/${ZIP_NAME}" --clobber
else
    gh release create "${VERSION}" \
        "build/${DMG_NAME}" \
        "build/${ZIP_NAME}" \
        --title "${VERSION}" \
        "${NOTES_ARGS[@]}"
fi

echo
echo "==> done"
echo "    DMG: build/${DMG_NAME}"
echo "    ZIP: build/${ZIP_NAME}"
