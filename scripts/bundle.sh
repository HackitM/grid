#!/bin/zsh
# Builds GRID and wraps the SwiftPM executable in a runnable .app bundle.
#
#   scripts/bundle.sh            # release build -> build/GRID.app (ad-hoc signed)
#   scripts/bundle.sh debug      # debug build
#   SIGN_ID="Developer ID Application: …" scripts/bundle.sh   # real signing (hardened runtime)
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
APP="build/GRID.app"

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Grid"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Grid"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# License notices for bundled third-party code (MIT requires shipping the notice).
mkdir -p "$APP/Contents/Resources/Licenses"
cp .build/checkouts/SwiftTerm/LICENSE "$APP/Contents/Resources/Licenses/SwiftTerm-LICENSE.txt"

if [[ -n "${SIGN_ID:-}" ]]; then
  codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP"
else
  codesign --force --sign - "$APP"   # ad-hoc: fine for local use, not for distribution
fi

echo "Built $APP ($CONFIG)"
