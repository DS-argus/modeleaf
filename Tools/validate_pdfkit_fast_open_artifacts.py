#!/usr/bin/env python3
"""Validate local crash/performance evidence without requesting macOS permissions."""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path
from typing import Any


MIB = 1024 * 1024
FIXTURE_RULES = {
    "S": (10, 1, 1 * MIB),
    "L": (300, 1, 8 * MIB),
    "F": (12, 20 * MIB, 40 * MIB),
    "B": (1, 1, 1 * MIB),
}


class ValidationFailure(RuntimeError):
    pass


class ValidationBlocked(RuntimeError):
    pass


def load_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as error:
        raise ValidationBlocked(f"missing artifact: {path}") from error
    except (OSError, json.JSONDecodeError) as error:
        raise ValidationFailure(f"invalid JSON artifact {path}: {error}") from error
    if not isinstance(value, dict):
        raise ValidationFailure(f"artifact root must be an object: {path}")
    return value


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValidationFailure(message)


def validate_record(identifier: str, record: Any) -> None:
    require(isinstance(record, dict), f"{identifier} record must be an object")
    path = Path(str(record.get("path", "")))
    require(path.is_file(), f"{identifier} PDF does not exist: {path}")
    require(record.get("validation") == "passed", f"{identifier} validation is not passed")
    require(record.get("locked") is False, f"{identifier} must be unlocked")
    require(record.get("byteSize") == path.stat().st_size, f"{identifier} byte size drifted")
    require(record.get("sha256") == sha256(path), f"{identifier} SHA-256 drifted")


def validate_manifest(path: Path) -> dict[str, Any]:
    manifest = load_json(path)
    require(manifest.get("schemaVersion") == 1, "manifest schemaVersion must be 1")
    permissions = manifest.get("permissionPolicy")
    require(isinstance(permissions, dict), "manifest permissionPolicy is missing")
    for key in (
        "appRuntimeRequiresAutomationPermission",
        "fixtureGenerationRequiresAutomationPermission",
        "manualCrashValidationRequiresAutomationPermission",
        "automatedKeyInjectionImplemented",
        "screenCaptureImplemented",
    ):
        require(permissions.get(key) is False, f"permission-free policy violated: {key}")

    fixtures = manifest.get("fixtures")
    require(isinstance(fixtures, dict), "manifest fixtures are missing")
    require(set(fixtures) == set(FIXTURE_RULES), "fixture set must be exactly S/L/F/B")
    for identifier, (pages, minimum, maximum) in FIXTURE_RULES.items():
        record = fixtures[identifier]
        validate_record(identifier, record)
        require(record.get("pageCount") == pages, f"{identifier} page count drifted")
        size = int(record["byteSize"])
        require(minimum <= size <= maximum, f"{identifier} size is outside its contract")
        if identifier == "B":
            require(record.get("sentinel") is None, "blank fixture must not have a sentinel")
        else:
            require(isinstance(record.get("sentinel"), dict), f"{identifier} sentinel is missing")

    original = manifest.get("originalPDF")
    if original is None:
        raise ValidationBlocked("original PDF O is not registered")
    validate_record("O", original)
    require(original.get("identifier") == "O", "original PDF identifier must be O")
    require(int(original.get("pageCount", 0)) > 0, "original PDF page count is invalid")

    crash = manifest.get("crashEvidence")
    require(isinstance(crash, dict), "crash evidence reference is missing")
    crash_path = Path(str(crash.get("path", "")))
    require(crash_path.is_file(), f"crash evidence does not exist: {crash_path}")
    require(crash.get("sha256") == sha256(crash_path), "crash evidence SHA-256 drifted")
    return manifest


def validate_manual_batch(path: Path, identifier: str) -> None:
    batch = load_json(path)
    require(batch.get("scenario") == "manual-hh-signed-release", f"{identifier} scenario mismatch")
    require(batch.get("status") == "passed", f"{identifier} manual batch did not pass")
    require(int(batch.get("expected_runs", 0)) >= 10, f"{identifier} requires at least 10 declared runs")
    require(batch.get("recorded_runs") == batch.get("expected_runs"), f"{identifier} has missing runs")
    require(batch.get("passed_runs") == batch.get("expected_runs"), f"{identifier} has non-passing runs")
    trials = batch.get("trials")
    require(isinstance(trials, list), f"{identifier} trials are missing")
    require(all(trial.get("status") == "passed" for trial in trials), f"{identifier} contains a non-pass")
    require(
        all(not trial.get("new_crash_reports") for trial in trials),
        f"{identifier} contains a new crash report",
    )


def validate_strict_gate(path: Path) -> None:
    gate = load_json(path)
    require(gate.get("schema_version") == 1, "gate-freeze schema_version must be 1")
    if gate.get("status") != "passed":
        raise ValidationBlocked(f"gate-freeze status is {gate.get('status', 'missing')}")

    containment = gate.get("containment")
    require(isinstance(containment, dict), "gate-freeze containment is missing")
    for identifier in ("F", "O"):
        entry = containment.get(identifier)
        require(isinstance(entry, dict), f"containment.{identifier} is missing")
        validate_manual_batch(Path(str(entry.get("batch", ""))), identifier)

    observer = gate.get("observer")
    if not isinstance(observer, dict) or observer.get("status") != "passed":
        raise ValidationBlocked("qualified acceptance observer evidence is missing")
    require(float(observer.get("median_perturbation", 1.0)) <= 0.05, "observer overhead exceeds 5%")
    require(int(observer.get("matched_pairs", 0)) == 20, "observer requires 20 matched pairs")

    acceptance = gate.get("acceptance")
    if not isinstance(acceptance, dict) or acceptance.get("status") != "passed":
        raise ValidationBlocked("final acceptance evidence is missing")
    fixtures = acceptance.get("fixtures")
    require(isinstance(fixtures, dict), "acceptance fixture evidence is missing")
    for identifier in ("S", "L", "F", "O"):
        evidence = fixtures.get(identifier)
        require(isinstance(evidence, dict), f"acceptance.{identifier} is missing")
        require(int(evidence.get("valid_trials", 0)) == 30, f"acceptance.{identifier} needs 30 trials")
        require(evidence.get("status") == "passed", f"acceptance.{identifier} did not pass")

    reviews = gate.get("reviews")
    require(isinstance(reviews, dict), "final review evidence is missing")
    require(reviews.get("verifier") == "approved", "verifier approval is missing")
    require(reviews.get("code_reviewer") == "approved", "code-reviewer approval is missing")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--gate-freeze", type=Path)
    parser.add_argument("--implementation-only", action="store_true")
    args = parser.parse_args()

    try:
        validate_manifest(args.manifest)
        if not args.implementation_only:
            if args.gate_freeze is None:
                raise ValidationBlocked("--gate-freeze is required for strict acceptance")
            validate_strict_gate(args.gate_freeze)
    except ValidationBlocked as error:
        print(json.dumps({"status": "blocked", "reason": str(error)}, sort_keys=True))
        return 2
    except ValidationFailure as error:
        print(json.dumps({"status": "failed", "reason": str(error)}, sort_keys=True))
        return 1

    mode = "implementation" if args.implementation_only else "strict-acceptance"
    print(json.dumps({"status": "passed", "mode": mode}, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
