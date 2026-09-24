#!/usr/bin/env bash
# Regenerates every PNG under packages/twenty-front/public/images/icons from
# lephlo/brand/logo.svg, keeping each file's original pixel size so manifest.json
# and index.html references stay valid. Non-square tiles get the logo centred on
# the brand background. Also writes the email logo (lephlo/brand/logo-150.png).
#
# Requires ImageMagick 7 (`magick`). Run from the repo root.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LOGO="$REPO_ROOT/lephlo/brand/logo.svg"
ICONS_DIR="$REPO_ROOT/packages/twenty-front/public/images/icons"
BACKGROUND="#1F3A5F"

command -v magick >/dev/null || { echo "ImageMagick 7 (magick) is required" >&2; exit 1; }

render() {
  local width="$1" height="$2" output="$3"
  local side=$(( width < height ? width : height ))
  magick -background none -density 600 "$LOGO" -resize "${side}x${side}" \
    -background "$BACKGROUND" -gravity center -extent "${width}x${height}" \
    -strip "$output"
}

count=0
while IFS= read -r -d '' icon; do
  read -r width height < <(magick identify -format '%w %h\n' "$icon")
  render "$width" "$height" "$icon"
  count=$((count + 1))
done < <(find "$ICONS_DIR" -name '*.png' -print0)

render 150 150 "$REPO_ROOT/lephlo/brand/logo-150.png"

echo "Regenerated $count app icons and lephlo/brand/logo-150.png"
