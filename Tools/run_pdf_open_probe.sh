#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

swift build -c release --product PDFReaderOpenProbe >/dev/null
BIN_DIR=$(swift build -c release --show-bin-path)
PROBE="$BIN_DIR/PDFReaderOpenProbe"

# Ad-hoc signing is local-only and needs no certificate, account, or macOS
# automation permission. Re-sign after each rebuild because the binary changed.
codesign --force --sign - --timestamp=none "$PROBE"
codesign --verify --strict "$PROBE"

exec "$PROBE" "$@"
