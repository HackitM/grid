#!/bin/zsh
# Builds GRID and wraps the SwiftPM executable in a runnable .app bundle.
#
#   scripts/bundle.sh            # release build -> build/GRID.app (ad-hoc signed)
#   scripts/bundle.sh debug      # debug build
#   scripts/bundle.sh qa         # debug build as build/GRID-QA.app with its own bundle ID and
#                                # preferences, so it can run beside your everyday GRID
#   SIGN_ID="Developer ID Application: …" scripts/bundle.sh   # real signing (hardened runtime)
set -euo pipefail

cd "$(dirname "$0")/.."
MODE="${1:-release}"
CONFIG="$MODE"
APP="${APP_OUT:-build/GRID.app}"      # APP_OUT=dist/GRID.app builds elsewhere (release script)
if [[ "$MODE" == "qa" ]]; then CONFIG="debug"; APP="build/GRID-QA.app"; fi

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Grid"

rm -rf "$APP"
mkdir -p "$(dirname "$APP")" "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Grid"
# Sandboxed runner for third-party widgets (docs/WIDGETS.md); lives beside the main binary.
cp "$(swift build -c "$CONFIG" --show-bin-path)/GridWidgetHost" "$APP/Contents/MacOS/GridWidgetHost"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [[ "$MODE" == "qa" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier local.grid.workspace.qa" -c "Set :CFBundleName GRID QA" \
    -c "Set :CFBundleDisplayName GRID QA" "$APP/Contents/Info.plist"
fi
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# License notices for bundled third-party code (MIT requires shipping the notice).
# Built-in site themes (the same files GRID's in-app theme updates are published from).
rm -rf "$APP/Contents/Resources/SiteThemes"
mkdir -p "$APP/Contents/Resources/SiteThemes"
cp site-themes/packs/*.css "$APP/Contents/Resources/SiteThemes/"
mkdir -p "$APP/Contents/Resources/Licenses"
cp .build/checkouts/SwiftTerm/LICENSE "$APP/Contents/Resources/Licenses/SwiftTerm-LICENSE.txt"
cp ThirdParty/readability/LICENSE.md "$APP/Contents/Resources/Licenses/Readability-LICENSE.md"

if [[ -n "${SIGN_ID:-}" ]]; then
  codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP/Contents/MacOS/GridWidgetHost"
  codesign --force --options runtime --timestamp --entitlements scripts/Grid.entitlements --sign "$SIGN_ID" "$APP"
else
  codesign --force --sign - "$APP/Contents/MacOS/GridWidgetHost"
  codesign --force --sign - "$APP"   # ad-hoc: fine for local use, not for distribution
fi

echo "Built $APP ($MODE)"
