#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$TASK_ROOT"
if [[ "${1:-}" != "--skip-build" ]]; then bash macos/scripts/build.sh; fi
BUILD_DIR="${GUI_NVM_DERIVED_DATA:-$HOME/Library/Caches/gui-nvm/DerivedData}"
APP_SOURCE="$BUILD_DIR/Build/Products/Release/gui-nvm.app"
OUTPUT="$TASK_ROOT/output/macos"
[[ -d "$APP_SOURCE" ]] || { printf '%s\n' 'Release app missing. Run build.sh first.' >&2; exit 1; }
mkdir -p "$OUTPUT"
/usr/sbin/dot_clean ./
# Only replace generated output artifacts, never an installed application or user data.
/usr/bin/codesign --force --sign - --options runtime --timestamp=none "$APP_SOURCE"
/usr/bin/ditto --norsrc --noextattr --noqtn "$APP_SOURCE" "$OUTPUT/gui-nvm.app"
/usr/sbin/dot_clean "$OUTPUT/gui-nvm.app"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$OUTPUT/gui-nvm.app"
STAGING="$(mktemp -d "${TMPDIR:-/tmp/}gui-nvm-dmg.XXXXXX")"
cleanup() { [[ -n "$STAGING" && "$STAGING" == "${TMPDIR:-/tmp/}"gui-nvm-dmg.* ]] && /bin/rm -rf -- "$STAGING"; }
trap cleanup EXIT
/usr/bin/ditto --norsrc --noextattr --noqtn "$APP_SOURCE" "$STAGING/gui-nvm.app"
/bin/ln -s /Applications "$STAGING/Applications"
/usr/sbin/dot_clean ./
DMG="$OUTPUT/gui-nvm-0.1.0-arm64.dmg"
/usr/bin/hdiutil create -volname gui-nvm -srcfolder "$STAGING" -ov -format UDZO "$DMG"
/usr/bin/hdiutil verify "$DMG"
(cd "$OUTPUT" && /usr/bin/shasum -a 256 "$(basename "$DMG")" > SHA256SUMS.txt)
/usr/sbin/dot_clean ./
printf '%s\n' "$OUTPUT/gui-nvm.app" "$DMG"
