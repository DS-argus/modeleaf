#!/bin/sh
# Build the local Release app, zip it as a distributable artifact, and print the
# version, zip path, and SHA-256 used by the Homebrew cask.
#
# This is the Tier-A (ad-hoc signed, un-notarized) packaging path. It needs no
# Apple Developer account. Consumers installing the resulting cask must clear
# Gatekeeper once in System Settings > Privacy & Security on first launch.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT="$ROOT/artifacts/release"
mkdir -p "$OUT"
cd "$ROOT"

# build_release_app.sh regenerates/validates the Xcode project, builds Release,
# ad-hoc signs, and prints the .app path on its last stdout line.
BUILD_OUTPUT=$("$ROOT/Tools/build_release_app.sh")
printf '%s\n' "$BUILD_OUTPUT" >&2
APP=$(printf '%s\n' "$BUILD_OUTPUT" | tail -n 1)
if [ ! -d "$APP" ]; then
  echo "package_release: no app bundle at '$APP'" >&2
  exit 1
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
ZIP="$OUT/Modeleaf-$VERSION.zip"

rm -f "$ZIP"
# ditto preserves bundle symlinks, resource forks, and code signature.
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"
SHA=$(/usr/bin/shasum -a 256 "$ZIP" | awk '{print $1}')

printf 'version=%s\n' "$VERSION"
printf 'zip=%s\n' "$ZIP"
printf 'sha256=%s\n' "$SHA"
