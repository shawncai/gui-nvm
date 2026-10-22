#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$TASK_ROOT"
BUILD_DIR="${GUI_NVM_DERIVED_DATA:-$HOME/Library/Caches/gui-nvm/DerivedData}"
python3 macos/scripts/generate-project.py
xcodebuild -project macos/GUINVM.xcodeproj -scheme GUINVM -configuration Debug -derivedDataPath "$BUILD_DIR" -destination 'platform=macOS,arch=arm64' test "$@"
/usr/sbin/dot_clean ./
