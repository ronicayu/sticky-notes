#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

echo "==> rendering icon PNGs"
swift scripts/generate-icon.swift

echo "==> assembling AppIcon.icns"
iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns

echo "==> done"
ls -la Resources/AppIcon.icns Resources/MenuBarIcon.png Resources/MenuBarIcon@2x.png
