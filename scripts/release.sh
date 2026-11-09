#!/bin/zsh
# Publishes a GitHub Release of GRID.
#
#   scripts/release.sh 0.3.0            # notes from docs/releases/0.3.0.md
#
# Checks: clean tree, Info.plist version matches, notes exist. Builds the release app into dist/
# (your build/GRID.app is left alone), zips it with ditto, writes a SHA-256, tags v<version> on the
# current commit and creates the release with the zip and checksum attached.
# Set SIGN_ID to a "Developer ID Application" identity to sign with the hardened runtime.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release.sh <version>}"
NOTES="docs/releases/$VERSION.md"
[[ -f "$NOTES" ]] || { echo "Missing release notes: $NOTES" >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "Commit or stash changes first." >&2; exit 1; }
PLIST=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
[[ "$PLIST" == "$VERSION" ]] || { echo "Info.plist says $PLIST, not $VERSION." >&2; exit 1; }
git rev-parse "v$VERSION" >/dev/null 2>&1 && { echo "Tag v$VERSION already exists." >&2; exit 1; }

swift test
rm -rf dist && mkdir -p dist
APP_OUT=dist/GRID.app scripts/bundle.sh release
ZIP="dist/GRID-$VERSION-macOS.zip"
ditto -c -k --sequesterRsrc --keepParent dist/GRID.app "$ZIP"
(cd dist && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")
cat "$ZIP.sha256"

gh release create "v$VERSION" "$ZIP" "$ZIP.sha256" --target "$(git rev-parse HEAD)" \
  --title "GRID $VERSION" --notes-file "$NOTES"
