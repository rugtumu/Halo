#!/bin/zsh
# Builds Halo/Assets.xcassets/AppIcon.appiconset from the Canva icon export.
# Usage: scripts/make-icon.sh path/to/canva-icon.(png|jpg)
set -euo pipefail
src=${1:?source image}
root=${0:A:h:h}
set_dir="$root/Halo/Assets.xcassets/AppIcon.appiconset"
mkdir -p "$set_dir"
tmp=$(mktemp -d)
swift "$root/scripts/IconMask.swift" "$src" "$tmp/master.png"
cp "$tmp/master.png" "$root/Vendor/icon-master.png"
images=""
for size in 16 32 128 256 512; do
  for scale in 1 2; do
    px=$(( size * scale )); name="icon_${size}x${size}@${scale}x.png"
    sips -z $px $px "$tmp/master.png" --out "$set_dir/$name" >/dev/null
    images+="{\"idiom\":\"mac\",\"size\":\"${size}x${size}\",\"scale\":\"${scale}x\",\"filename\":\"$name\"},"
  done
done
print -r -- "{\"images\":[${images%,}],\"info\":{\"author\":\"xcode\",\"version\":1}}" > "$set_dir/Contents.json"
print -r -- '{"info":{"author":"xcode","version":1}}' > "$root/Halo/Assets.xcassets/Contents.json"
rm -rf "$tmp"
echo "AppIcon updated from $src"
