#!/bin/sh
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
LOCAL="$ROOT/artifacts/verification/pdfkit-fast-open/local/evaluator"
MANIFEST=
GATE_FREEZE=
IMPLEMENTATION_ONLY=false

usage() {
  cat <<'EOF'
Usage:
  Tools/evaluate_pdfkit_fast_open.sh --manifest <json> [--gate-freeze <json>] [--implementation-only]

Exit 0: passed, exit 1: failed, exit 2: blocked prerequisite/evidence.
The default mode is the strict performance-goal contract. --implementation-only
proves source, tests, fixture integrity, Release build, and signatures without
pretending that the user's manual GUI acceptance has already happened.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --manifest) MANIFEST=$2; shift 2 ;;
    --gate-freeze) GATE_FREEZE=$2; shift 2 ;;
    --implementation-only) IMPLEMENTATION_ONLY=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 64 ;;
  esac
done

[ -n "$MANIFEST" ] || { usage >&2; exit 64; }
mkdir -p "$LOCAL"
cd "$ROOT"

write_result() {
  status=$1
  phase=$2
  reason=$3
  STATUS_VALUE="$status" PHASE_VALUE="$phase" REASON_VALUE="$reason" \
    IMPLEMENTATION_VALUE="$IMPLEMENTATION_ONLY" python3 - "$LOCAL/last-result.json" <<'PY'
import json, os, sys
from datetime import datetime, timezone
payload = {
    "schema_version": 1,
    "status": os.environ["STATUS_VALUE"],
    "phase": os.environ["PHASE_VALUE"],
    "reason": os.environ["REASON_VALUE"],
    "implementation_only": os.environ["IMPLEMENTATION_VALUE"] == "true",
    "recorded_at": datetime.now(timezone.utc).isoformat(),
}
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
}

fail() {
  write_result failed "$1" "$2"
  echo "FAILED [$1]: $2" >&2
  exit 1
}

run_step() {
  name=$1
  shift
  log="$LOCAL/$name.log"
  echo "==> $name"
  if "$@" >"$log" 2>&1; then
    echo "    passed"
  else
    code=$?
    tail -n 80 "$log" >&2 || true
    fail "$name" "command exited $code"
  fi
}

echo "==> source-audit"
if grep -Eq 'override[[:space:]]+var[[:space:]]+document' PDFReaderApp/Input/ReaderPDFView.swift; then
  fail source-audit "ReaderPDFView.document override is present"
fi
if grep -R -nE 'PDFPageAnalyzerV2|formFillingQueue|nonisolated\(unsafe\)|PDF_READER_TEST|fixtureURLOverride|configURLOverride' PDFReaderApp >"$LOCAL/source-forbidden.log"; then
  fail source-audit "forbidden private, actor-escape, or production-test token found"
fi
python3 - <<'PY' || fail source-audit "dependency or product boundary drifted"
from pathlib import Path
package = Path("Package.swift").read_text(encoding="utf-8")
assert package.count(".package(") == 1
assert "https://github.com/dduan/TOMLDecoder.git" in package
assert 'exact: "0.4.5"' in package
metrics = Path("PDFReaderApp/Reader/PDFOpenMetrics.swift").read_text(encoding="utf-8")
marker = metrics[metrics.index('let marker = ['):]
assert 'url=' not in marker.lower()
assert 'path=' not in marker.lower()
assert 'open.closed' not in metrics
PY
echo "    passed"

run_step swift-tests \
  swift test --parallel -Xswiftc -warnings-as-errors
run_step xcode-project-generation python3 Tools/generate_xcode_project.py
run_step xcode-project-validation python3 Tools/validate_xcode_project.py

rm -rf "$LOCAL/ModeleafUnitTests.xcresult"
run_step xcode-unit-tests \
  xcodebuild -project Modeleaf.xcodeproj -scheme Modeleaf \
    -configuration Debug -destination 'platform=macOS,arch=arm64' \
    -only-testing:PDFReaderCoreTests -only-testing:PDFReaderAppTests \
    -resultBundlePath "$LOCAL/ModeleafUnitTests.xcresult" test

run_step release-build Tools/build_release_app.sh
ORIGINAL_PDF=$(python3 - "$MANIFEST" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    print(json.load(handle)["originalPDF"]["path"])
PY
) || fail probe-signature "could not resolve original PDF from manifest"
run_step probe-signature Tools/run_pdf_open_probe.sh inspect --pdf "$ORIGINAL_PDF"

validator_args="--manifest $MANIFEST"
if [ -n "$GATE_FREEZE" ]; then
  validator_args="$validator_args --gate-freeze $GATE_FREEZE"
fi
if [ "$IMPLEMENTATION_ONLY" = true ]; then
  validator_args="$validator_args --implementation-only"
fi

echo "==> artifact-validation"
# All paths in this workflow are local and intentionally contain no shell
# metacharacters. Split the assembled option list for the small Python CLI.
# shellcheck disable=SC2086
python3 Tools/validate_pdfkit_fast_open_artifacts.py $validator_args \
  >"$LOCAL/artifact-validation.log" 2>&1
validator_status=$?
cat "$LOCAL/artifact-validation.log"
case "$validator_status" in
  0)
    write_result passed evaluator "all applicable gates passed"
    echo "PASS"
    exit 0
    ;;
  2)
    write_result blocked artifact-validation "strict GUI/performance evidence is pending"
    echo "BLOCKED: strict GUI/performance evidence is pending" >&2
    exit 2
    ;;
  *)
    fail artifact-validation "artifact validation failed"
    ;;
esac
