#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

usage() {
  cat <<'EOF'
Usage:
  Tools/verify.sh focused <test-filter> [swift-test-options...]
  Tools/verify.sh core [swift-test-options...]
  Tools/verify.sh app [swift-test-options...]
  Tools/verify.sh full [swift-test-options...]
EOF
}

mode=${1:-}
case "$mode" in
  focused)
    filter=${2:-}
    if [ -z "$filter" ]; then
      usage >&2
      exit 2
    fi
    shift 2
    swift test --filter "$filter" "$@"
    ;;
  core)
    shift
    swift test --filter PDFReaderCoreTests "$@"
    ;;
  app)
    shift
    swift test --filter PDFReaderAppTests "$@"
    ;;
  full)
    shift
    swift test "$@"
    python3 Tools/validate_xcode_project.py
    git diff --check
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
