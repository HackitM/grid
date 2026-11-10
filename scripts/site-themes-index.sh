#!/bin/zsh
# Rebuilds site-themes/index.json from the packs in site-themes/packs/ (id and version from each
# pack's header, SHA-256 of the file). Run after editing a pack, bump its `version:` first, then
# commit and push: GRID picks up packs newer than its own from the repository's master branch.
#
#   scripts/site-themes-index.sh            # write index.json
#   MINIMUM_APP=1.1.0 scripts/site-themes-index.sh   # mark every pack as needing GRID 1.1.0+
set -euo pipefail
cd "$(dirname "$0")/../site-themes"
out=index.json.tmp
print -r -- '{' > $out
print -r -- '  "format": 1,' >> $out
print -r -- '  "packs": [' >> $out
first=1
for f in packs/*.css(N); do
  id=$(sed -n 's/^id:[[:space:]]*//p' "$f" | head -1)
  ver=$(sed -n 's/^version:[[:space:]]*//p' "$f" | head -1)
  sha=$(shasum -a 256 "$f" | cut -d' ' -f1)
  [[ -n "$id" && -n "$ver" ]] || { echo "Missing id or version in $f" >&2; exit 1; }
  (( first )) || print -r -- ',' >> $out
  first=0
  min=""
  [[ -n "${MINIMUM_APP:-}" ]] && min=", \"minimumApp\": \"$MINIMUM_APP\""
  print -rn -- "    {\"id\": \"$id\", \"version\": $ver, \"file\": \"${f:t}\", \"sha256\": \"$sha\"$min}" >> $out
done
print -r -- '' >> $out
print -r -- '  ]' >> $out
print -r -- '}' >> $out
mv $out index.json
echo "Wrote site-themes/index.json"
