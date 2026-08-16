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
  Tools/verify.sh hygiene [base-sha head-sha]
EOF
}

check_diff_hygiene() {
  git diff --check
  git diff --cached --check
  if [ "$#" -eq 2 ]; then
    git diff --check "$1" "$2"
  elif base=$(git merge-base HEAD origin/main 2>/dev/null); then
    git diff --check "$base" HEAD
  fi
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
    check_diff_hygiene
    ;;
  hygiene)
    shift
    if [ "$#" -ne 0 ] && [ "$#" -ne 2 ]; then
      usage >&2
      exit 2
    fi
    check_diff_hygiene "$@"
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
