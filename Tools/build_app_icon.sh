#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
MASTER="$ROOT/Assets/AppIcon/AppIcon-1024.png"
OUTPUT="$ROOT/PDFReaderApp/Resources/AppIcon.icns"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/modeleaf-icon.XXXXXX")
ICONSET="$WORK/AppIcon.iconset"

cleanup() {
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

if [ ! -f "$MASTER" ]; then
  printf 'Missing icon master: %s\n' "$MASTER" >&2
  exit 1
fi

mkdir -p "$ICONSET"

make_icon() {
  size=$1
  name=$2
  sips -z "$size" "$size" "$MASTER" --out "$ICONSET/$name" >/dev/null
}

make_icon 16 icon_16x16.png
make_icon 32 icon_16x16@2x.png
make_icon 32 icon_32x32.png
make_icon 64 icon_32x32@2x.png
make_icon 128 icon_128x128.png
make_icon 256 icon_128x128@2x.png
make_icon 256 icon_256x256.png
make_icon 512 icon_256x256@2x.png
make_icon 512 icon_512x512.png
make_icon 1024 icon_512x512@2x.png

iconutil -c icns "$ICONSET" -o "$OUTPUT"

printf '%s\n' "$OUTPUT"
