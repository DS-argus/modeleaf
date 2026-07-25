#!/bin/sh
set -eu

usage() {
  cat <<'EOF'
Usage:
  Tools/run_manual_pdfkit_stress.sh --app <Modeleaf.app> --pdf <file.pdf> \
    [--runs 10] [--output <directory>]

No Accessibility, Input Monitoring, Automation, or Screen Recording permission
is requested. The script launches a fresh signed Release process; you press h
twice normally and record the visible result.
EOF
}

APP=
PDF=
RUNS=10
OUTPUT=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --app) APP=$2; shift 2 ;;
    --pdf) PDF=$2; shift 2 ;;
    --runs) RUNS=$2; shift 2 ;;
    --output) OUTPUT=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 64 ;;
  esac
done

[ -d "$APP" ] || { echo "Missing app: $APP" >&2; exit 64; }
[ -f "$PDF" ] || { echo "Missing PDF: $PDF" >&2; exit 64; }
case "$RUNS" in *[!0-9]*|'') echo "--runs must be a positive integer" >&2; exit 64 ;; esac
[ "$RUNS" -gt 0 ] || { echo "--runs must be positive" >&2; exit 64; }

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if [ -z "$OUTPUT" ]; then
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  OUTPUT="$ROOT/artifacts/verification/pdfkit-fast-open/local/manual-stress/$stamp"
fi
mkdir -p "$OUTPUT"
APP=$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")
PDF=$(cd "$(dirname "$PDF")" && pwd)/$(basename "$PDF")
codesign --verify --deep --strict "$APP"

list_pids() { pgrep -x Modeleaf 2>/dev/null | sort -n || true; }
list_crashes() {
  find "$HOME/Library/Logs/DiagnosticReports" -maxdepth 1 -type f \
    -name 'Modeleaf*.ips' -print 2>/dev/null | sort || true
}

write_trial() {
  target=$1
  APP_PATH="$APP" PDF_PATH="$PDF" RUN_NUMBER="$run" PID_VALUE="${pid:-}" \
    STATUS_VALUE="$status" REASON_VALUE="$reason" NEW_CRASHES="$new_crashes" \
    python3 - "$target" <<'PY'
import json, os, sys
from datetime import datetime, timezone
payload = {
    "schema_version": 1,
    "scenario": "manual-hh-signed-release",
    "run": int(os.environ["RUN_NUMBER"]),
    "status": os.environ["STATUS_VALUE"],
    "reason": os.environ["REASON_VALUE"],
    "app": os.environ["APP_PATH"],
    "pdf": os.environ["PDF_PATH"],
    "pid": int(os.environ["PID_VALUE"]) if os.environ["PID_VALUE"] else None,
    "key_sequence": ["h", "h"],
    "new_crash_reports": [p for p in os.environ["NEW_CRASHES"].split(";") if p],
    "recorded_at": datetime.now(timezone.utc).isoformat(),
}
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(payload, handle, ensure_ascii=False, indent=2, sort_keys=True)
    handle.write("\n")
PY
}

overall=passed
run=1
while [ "$run" -le "$RUNS" ]; do
  run_id=$(printf '%02d' "$run")
  temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/modeleaf-manual.XXXXXX")
  copy="$temp_dir/$(basename "$PDF")"
  cp "$PDF" "$copy"
  list_pids > "$temp_dir/before-pids"
  list_crashes > "$temp_dir/before-crashes"

  echo
  echo "[$run/$RUNS] Launching a fresh Release process with: $(basename "$PDF")"
  open -n -a "$APP" "$copy"

  pid=
  attempt=0
  while [ "$attempt" -lt 100 ]; do
    list_pids > "$temp_dir/after-pids"
    pid=$(comm -13 "$temp_dir/before-pids" "$temp_dir/after-pids" | tail -n 1)
    [ -n "$pid" ] && break
    sleep 0.1
    attempt=$((attempt + 1))
  done

  status=invalid
  reason=fresh-process-not-observed
  if [ -n "$pid" ]; then
    echo "  1. 첫 페이지가 보이면 Modeleaf 창에서 h를 두 번 누르세요."
    echo "  2. 앱이 유지되고 입력이 정상 동작하는지 확인하세요."
    printf '  결과 [p=pass, f=crash/hang/failure, q=stop]: '
    IFS= read -r response
    case "$response" in
      p|P)
        if kill -0 "$pid" 2>/dev/null; then
          status=passed; reason=manual-hh-survived
        else
          status=failed; reason=process-exited-before-pass
        fi ;;
      f|F) status=failed; reason=manual-failure-reported ;;
      q|Q) status=blocked; reason=operator-stopped ;;
      *) status=invalid; reason=unrecognized-response ;;
    esac
  fi

  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    wait_count=0
    while kill -0 "$pid" 2>/dev/null && [ "$wait_count" -lt 100 ]; do
      sleep 0.1
      wait_count=$((wait_count + 1))
    done
    kill -KILL "$pid" 2>/dev/null || true
  fi

  sleep 2
  list_crashes > "$temp_dir/after-crashes"
  new_crashes=$(comm -13 "$temp_dir/before-crashes" "$temp_dir/after-crashes" | tr '\n' ';')
  if [ -n "$new_crashes" ]; then
    status=failed; reason=new-diagnostic-report
  fi

  write_trial "$OUTPUT/trial-$run_id.json"
  echo "  $status: $reason"
  rm -rf "$temp_dir"
  if [ "$status" != passed ]; then
    overall=$status
    [ "$status" = blocked ] && break
  fi
  run=$((run + 1))
done

OUTPUT_DIR="$OUTPUT" EXPECTED_RUNS="$RUNS" OVERALL_STATUS="$overall" \
  python3 - "$OUTPUT/batch.json" <<'PY'
import glob, json, os, sys
from datetime import datetime, timezone
trials = []
for path in sorted(glob.glob(os.path.join(os.environ["OUTPUT_DIR"], "trial-*.json"))):
    with open(path, encoding="utf-8") as handle:
        trials.append(json.load(handle))
payload = {
    "schema_version": 1,
    "scenario": "manual-hh-signed-release",
    "status": os.environ["OVERALL_STATUS"],
    "expected_runs": int(os.environ["EXPECTED_RUNS"]),
    "recorded_runs": len(trials),
    "passed_runs": sum(t["status"] == "passed" for t in trials),
    "trials": trials,
    "recorded_at": datetime.now(timezone.utc).isoformat(),
}
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(payload, handle, ensure_ascii=False, indent=2, sort_keys=True)
    handle.write("\n")
PY

echo "Evidence: $OUTPUT/batch.json"
[ "$overall" = passed ] || exit 2
