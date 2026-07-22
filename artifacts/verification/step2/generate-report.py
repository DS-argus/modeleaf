#!/usr/bin/env python3
"""Validate and summarize the Step 2 frozen action/binding contract."""

from __future__ import annotations

import hashlib
import json
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
EVIDENCE = ROOT / "artifacts" / "verification" / "step2"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def read(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


def sha256(relative: str) -> str:
    return hashlib.sha256((ROOT / relative).read_bytes()).hexdigest()


def main() -> None:
    contract = json.loads(read("artifacts/verification/step2/contract.json"))
    action_ids = [action["id"] for action in contract["actions"]]
    require(len(action_ids) == 27, "the v1 action contract must contain exactly 27 actions")
    require(len(set(action_ids)) == len(action_ids), "action identifiers must be unique")
    require(
        contract["inputContexts"] == ["navigation", "pagePrompt", "searchPrompt", "searchResults"],
        "the v1 input-context order changed",
    )
    require(len(contract["themes"]) == 4, "the v1 theme set must contain four themes")
    require(contract["surfaces"]["count"] == 51, "the v1 action-surface count changed")

    prompt_snapshot = read("PDFReaderCoreTests/Snapshots/PromptNativeReservationV1.txt").splitlines()
    system_snapshot = read("PDFReaderCoreTests/Snapshots/SystemKeyReservationV1.txt").splitlines()
    require(contract["reservations"]["promptNative"] == prompt_snapshot, "prompt reservation drift")
    require(contract["reservations"]["system"] == system_snapshot, "system reservation drift")

    excluded_features = [
        "annotation",
        "bookmark",
        "command-palette",
        "highlight",
        "mark",
        "ocr",
        "portal",
        "script",
        "smart-jump",
    ]
    forbidden_action_ids = [
        action_id
        for action_id in action_ids
        if any(term in action_id.lower() for term in excluded_features)
    ]
    require(not forbidden_action_ids, f"excluded feature leaked into action IDs: {forbidden_action_ids}")

    imports: dict[str, list[str]] = {}
    for source in sorted((ROOT / "PDFReaderCore").rglob("*.swift")):
        modules = re.findall(r"^import\s+([A-Za-z_][A-Za-z0-9_]*)\s*$", source.read_text(), re.MULTILINE)
        imports[str(source.relative_to(ROOT))] = modules
    imported_modules = sorted({module for modules in imports.values() for module in modules})
    require(imported_modules == ["Foundation"], f"core import boundary changed: {imported_modules}")

    swift_test = read("artifacts/verification/step2/swift-test.log")
    swift_release = read("artifacts/verification/step2/swift-build-release.log")
    xcode_debug = read("artifacts/verification/step2/xcode-build-debug.log")
    xcode_tests = read("artifacts/verification/step2/xcode-unit-tests.log")
    xcode_release = read("artifacts/verification/step2/xcode-build-release.log")
    require("Test run with 26 tests in 4 suites passed" in swift_test, "SwiftPM test count/result drift")
    require("Build complete!" in swift_release, "SwiftPM Release build did not complete")
    require("** BUILD SUCCEEDED **" in xcode_debug, "Xcode Debug build did not succeed")
    require("Test run with 22 tests in 3 suites passed" in xcode_tests, "Xcode core tests did not pass")
    require("Executed 1 test, with 0 failures" in xcode_tests, "Xcode app test did not pass")
    require("** TEST SUCCEEDED **" in xcode_tests, "Xcode test action did not succeed")
    require("** BUILD SUCCEEDED **" in xcode_release, "Xcode Release build did not succeed")

    combined_xcode = "\n".join([xcode_debug, xcode_tests, xcode_release])
    linker_warnings = re.findall(r".*(?:ld: warning|ignoring file .*architecture).*$", combined_xcode, re.MULTILINE)
    isolation_warnings = re.findall(r".*main actor-isolated.*warning.*$|.*warning:.*main actor-isolated.*$", combined_xcode, re.MULTILINE)
    require(not linker_warnings, "Xcode emitted a linker architecture warning")
    require(not isolation_warnings, "Xcode emitted a Swift actor-isolation warning")

    project_validation = json.loads(read("artifacts/verification/step2/xcode-project-validation.json"))
    require(project_validation["status"] == "passed", "generated Xcode project validation failed")
    require(project_validation["debugArchitectures"] == "active only", "Debug architecture policy drift")

    app_intents_warnings = combined_xcode.count(
        "warning: Metadata extraction skipped. No AppIntents.framework dependency found."
    )
    environment_warning_count = sum(
        combined_xcode.count(marker)
        for marker in [
            "CoreSimulatorService connection interrupted",
            "Unable to discover any Simulator device types",
            "Unable to discover any Simulator runtimes",
            "Failed to remount the Metal Toolchain",
        ]
    )

    source_audit = {
        "status": "passed",
        "coreImportedModules": imported_modules,
        "files": imports,
        "excludedSioyekStyleFeatures": excluded_features,
        "forbiddenActionIDs": forbidden_action_ids,
    }
    (EVIDENCE / "source-scope-audit.json").write_text(
        json.dumps(source_audit, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )

    report = {
        "status": "passed",
        "story": "G003-step-2-freeze-actions-and-bindings",
        "contract": {
            "actions": len(action_ids),
            "contexts": len(contract["inputContexts"]),
            "promptNativeReservations": len(prompt_snapshot),
            "systemReservations": len(system_snapshot),
            "themes": len(contract["themes"]),
            "menuItems": len(contract["menus"]),
            "actionSurfaces": contract["surfaces"]["count"],
            "defaultConfigSHA256": sha256("PDFReaderApp/Resources/DefaultConfig.toml"),
            "configDocumentationSHA256": sha256("CONFIG.md"),
        },
        "verification": {
            "swiftPM": {"tests": 26, "suites": 4, "releaseBuild": "passed"},
            "xcode": {
                "debugBuild": "passed",
                "coreTests": 22,
                "coreSuites": 3,
                "appTests": 1,
                "releaseBuild": "passed",
            },
            "projectGraph": project_validation,
            "sourceScopeAudit": "source-scope-audit.json",
            "publicInterface": [
                "PDFReaderCore-arm64.abi.json",
                "PDFReaderCore-x86_64.abi.json",
            ],
        },
        "warningDisposition": {
            "linkerArchitectureWarnings": len(linker_warnings),
            "swiftActorIsolationWarnings": len(isolation_warnings),
            "benignAppIntentsMetadataWarnings": app_intents_warnings,
            "localXcodeEnvironmentWarnings": environment_warning_count,
        },
    }
    (EVIDENCE / "report.json").write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print(json.dumps(report, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
