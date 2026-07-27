#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
LOCAL="$ROOT/artifacts/verification/pdfkit-fast-open/local"
DERIVED_DATA="$LOCAL/DerivedData"
LOG_DIR="$LOCAL/release"
APP="$DERIVED_DATA/Build/Products/Release/Modeleaf.app"

mkdir -p "$LOG_DIR"
cd "$ROOT"

python3 Tools/generate_xcode_project.py
python3 Tools/validate_xcode_project.py

set -o pipefail
xcodebuild \
  -project Modeleaf.xcodeproj \
  -scheme Modeleaf \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED_DATA" \
  ${XCODEBUILD_EXTRA_ARGS:-} \
  build 2>&1 | tee "$LOG_DIR/xcode-release-build.log"

codesign --verify --deep --strict --verbose=2 "$APP" \
  2>&1 | tee "$LOG_DIR/codesign-verify.log"
codesign -dv --verbose=4 "$APP" \
  2>&1 | tee "$LOG_DIR/codesign-details.log"
shasum -a 256 "$APP/Contents/MacOS/Modeleaf" \
  | tee "$LOG_DIR/binary-sha256.log"

printf '%s\n' "$APP"
