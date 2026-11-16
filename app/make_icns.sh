#!/bin/sh
# Turns app/icon.png (1024px) into app/AppIcon.icns.
set -e
cd "$(dirname "$0")"
tmp=$(mktemp -d)
set_dir="$tmp/AppIcon.iconset"
mkdir "$set_dir"
for s in 16 32 128 256 512; do
    d=$((s * 2))
    sips -z $s $s icon.png --out "$set_dir/icon_${s}x${s}.png" >/dev/null
    sips -z $d $d icon.png --out "$set_dir/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$set_dir" -o AppIcon.icns
rm -rf "$tmp"
