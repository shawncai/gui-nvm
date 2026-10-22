#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$TASK_ROOT"
BUILD_DIR="${GUI_NVM_DERIVED_DATA:-$HOME/Library/Caches/gui-nvm/DerivedData}"
xcrun swift macos/scripts/make-icon.swift macos
python3 macos/scripts/generate-project.py
xcodebuild -project macos/GUINVM.xcodeproj -scheme GUINVM -configuration Release -derivedDataPath "$BUILD_DIR" -destination 'platform=macOS,arch=arm64' build
/usr/sbin/dot_clean ./
printf '%s\n' "$BUILD_DIR/Build/Products/Release/gui-nvm.app"
