#!/usr/bin/env bash
# Regenerates every PNG under packages/twenty-front/public/images/icons from
# lephlo/brand/lephlo-mark.svg (Lephlo Brand Guidelines v1.0), keeping each
# file's original pixel size so manifest.json and index.html references stay
# valid. The mark sits on the kit's light surface with the kit's clearspace
# rule (¼ of the mark height on every side). Also writes the email logo
# (lephlo/brand/logo-150.png, transparent).
#
# Requires ImageMagick 7 (`magick`). Run from anywhere.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MARK="$REPO_ROOT/lephlo/brand/lephlo-mark.svg"
ICONS_DIR="$REPO_ROOT/packages/twenty-front/public/images/icons"
SURFACE="#F2F5F6"

command -v magick >/dev/null || { echo "ImageMagick 7 (magick) is required" >&2; exit 1; }

# Clearspace of ¼ mark height on both sides → mark occupies 2/3 of the tile.
render() {
  local width="$1" height="$2" background="$3" output="$4"
  local side=$(( width < height ? width : height ))
  local mark=$(( side * 2 / 3 ))
  magick -background none -density 600 "$MARK" -resize "${mark}x${mark}" \
    -background "$background" -gravity center -extent "${width}x${height}" \
    -strip "$output"
}

count=0
while IFS= read -r -d '' icon; do
  read -r width height < <(magick identify -format '%w %h\n' "$icon")
  render "$width" "$height" "$SURFACE" "$icon"
  count=$((count + 1))
done < <(find "$ICONS_DIR" -name '*.png' -print0)

render 150 150 none "$REPO_ROOT/lephlo/brand/logo-150.png"

echo "Regenerated $count app icons and lephlo/brand/logo-150.png"
