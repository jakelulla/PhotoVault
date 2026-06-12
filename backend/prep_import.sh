#!/bin/bash
# Flatten the macOS Photos library originals into a single folder of JPEG/PNG
# stills: copy JPEG/PNG as-is, convert HEIC->JPEG (sips, macOS-native), skip video.
# Output is used both as the new test_images (backend dataset) and the set
# imported into the Simulator Photos app.
set -euo pipefail

LIB="/Users/jakelulla/Pictures/Photos Library.photoslibrary"
OUT="/Users/jakelulla/Desktop/PhotoSearch/_import"
rm -rf "$OUT"; mkdir -p "$OUT"

n_jpg=0; n_png=0; n_heic=0
while IFS= read -r f; do
  base="$(basename "$f")"
  ext="$(echo "${base##*.}" | tr 'A-Z' 'a-z')"
  stem="${base%.*}"
  case "$ext" in
    jpg|jpeg) cp "$f" "$OUT/$stem.jpg"; n_jpg=$((n_jpg+1)) ;;
    png)      cp "$f" "$OUT/$stem.png"; n_png=$((n_png+1)) ;;
    heic)     sips -s format jpeg "$f" --out "$OUT/$stem.jpg" >/dev/null 2>&1 && n_heic=$((n_heic+1)) ;;
  esac
done < <(find "$LIB/originals" \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" -o -iname "*.heic" \) -type f)

echo "staged: $n_jpg jpeg, $n_png png, $n_heic heic->jpg  => $(ls "$OUT" | wc -l | tr -d ' ') files in $OUT"
