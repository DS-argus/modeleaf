#!/usr/bin/env python3
"""Validate and summarize the deterministic key-engine story evidence."""

from __future__ import annotations

import json
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
EVIDENCE = ROOT / "artifacts" / "verification" / "step3"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def read(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


def main() -> None:
    trace = json.loads(read("artifacts/verification/step3/trace.json"))
    require(trace["status"] == "passed", "executable key-engine trace did not pass")
    expected_trace_checks = {
        "g12ResolvedPage": 12,
        "staleEpochBlocked": True,
        "defaultLongerSequences": ["gg", "gt", "gT"],
        "repeatPolicyApplied": True,
        "promptNativePrecedence": True,
        "implicitCountGrammar": False,
        "unsafeExactPrefixRejected": True,
    }
    require(trace["checks"] == expected_trace_checks, "key-engine trace contract drifted")

    engine_tests = read("PDFReaderCoreTests/KeySequenceEngineTests.swift")
    expected_test_ids = [
        *(f"U-SEQ-{number:02d}" for number in range(1, 9)),
        *(f"U-CTX-{number:02d}" for number in range(1, 7)),
    ]
    missing_test_ids = [test_id for test_id in expected_test_ids if test_id not in engine_tests]
    require(not missing_test_ids, f"missing key-engine test IDs: {missing_test_ids}")
    require(
        not re.search(r"\b(?:sleep|usleep|Task\.sleep)\b", engine_tests),
        "key-engine tests must use explicit epochs rather than real time",
    )

    imports: dict[str, list[str]] = {}
    for source in sorted((ROOT / "PDFReaderCore").rglob("*.swift")):
        modules = re.findall(r"^import\s+([A-Za-z_][A-Za-z0-9_]*)\s*$", source.read_text(), re.MULTILINE)
        imports[str(source.relative_to(ROOT))] = modules
    imported_modules = sorted({module for modules in imports.values() for module in modules})
    require(imported_modules == ["Foundation"], f"core import boundary changed: {imported_modules}")

    new_core_files = [
        "PDFReaderCore/Input/KeySequenceTrie.swift",
        "PDFReaderCore/Input/KeySequenceEngine.swift",
        "PDFReaderCore/Input/PageNumberInputBuffer.swift",
    ]
    for relative in new_core_files:
        require((ROOT / relative).is_file(), f"missing key-engine source: {relative}")
    core_text = "\n".join(read(relative) for relative in new_core_files)
    require("import AppKit" not in core_text and "import PDFKit" not in core_text, "platform API leaked into core")

    swift_test = read("artifacts/verification/step3/swift-test.log")
    swift_release = read("artifacts/verification/step3/swift-build-release.log")
    xcode_debug = read("artifacts/verification/step3/xcode-build-debug.log")
    xcode_tests = read("artifacts/verification/step3/xcode-unit-tests.log")
    xcode_analyze = read("artifacts/verification/step3/xcode-analyze.log")
    xcode_release = read("artifacts/verification/step3/xcode-build-release.log")
    require("Test run with 41 tests in 5 suites passed" in swift_test, "SwiftPM test result drift")
    require("Build complete!" in swift_release, "SwiftPM Release build did not complete")
    require("** BUILD SUCCEEDED **" in xcode_debug, "Xcode Debug build did not succeed")
    require("Test run with 37 tests in 4 suites passed" in xcode_tests, "Xcode core tests did not pass")
    require("Executed 1 test, with 0 failures" in xcode_tests, "Xcode app test did not pass")
    require("** TEST SUCCEEDED **" in xcode_tests, "Xcode test action did not succeed")
    require("** ANALYZE SUCCEEDED **" in xcode_analyze, "Xcode analyze did not succeed")
    require("** BUILD SUCCEEDED **" in xcode_release, "Xcode Release build did not succeed")

    project_validation = json.loads(read("artifacts/verification/step3/xcode-project-validation.json"))
    require(project_validation["status"] == "passed", "generated Xcode project validation failed")

    combined_xcode = "\n".join([xcode_debug, xcode_tests, xcode_analyze, xcode_release])
    linker_warnings = re.findall(r".*(?:ld: warning|ignoring file .*architecture).*$", combined_xcode, re.MULTILINE)
    isolation_warnings = re.findall(r".*warning:.*main actor-isolated.*$", combined_xcode, re.MULTILINE)
    require(not linker_warnings, "Xcode emitted a linker architecture warning")
    require(not isolation_warnings, "Xcode emitted an actor-isolation warning")
    app_intents_warnings = combined_xcode.count(
        "warning: Metadata extraction skipped. No AppIntents.framework dependency found."
    )
    other_compiler_warnings = [
        line
        for line in combined_xcode.splitlines()
        if "warning:" in line
        and "Metadata extraction skipped. No AppIntents.framework dependency found." not in line
    ]
    require(not other_compiler_warnings, f"unexpected Xcode warning: {other_compiler_warnings}")

    source_audit = {
        "status": "passed",
        "coreImportedModules": imported_modules,
        "files": imports,
        "newCoreFiles": new_core_files,
        "deterministicClock": "explicit PrefixEpoch callbacks; no sleep APIs",
        "testIDs": expected_test_ids,
    }
    (EVIDENCE / "source-scope-audit.json").write_text(
        json.dumps(source_audit, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )

    report = {
        "status": "passed",
        "story": "G004-step-3-implement-key-engine",
        "contract": {
            "prefixTrie": "exact, prefix, exact-and-prefix, no-match",
            "semanticPageReplay": "g + ASCII digits, one-based PageNumberInputBuffer",
            "defaultLongerSequences": ["gg", "gt", "gT"],
            "prefixTimeoutMilliseconds": 500,
            "epochInvalidations": [
                "contextChanged",
                "configurationChanged",
                "focusLost",
                "sessionChanged",
                "sessionClosed",
                "promptCommitted",
                "promptCancelled",
                "explicitCancel",
            ],
            "implicitCountGrammar": False,
        },
        "verification": {
            "swiftPM": {"tests": 41, "suites": 5, "releaseBuild": "passed"},
            "xcode": {
                "debugBuild": "passed",
                "coreTests": 37,
                "coreSuites": 4,
                "appTests": 1,
                "analyze": "passed",
                "releaseBuild": "passed",
            },
            "trace": "trace.json",
            "sourceScopeAudit": "source-scope-audit.json",
            "publicInterface": [
                "PDFReaderCore-arm64.abi.json",
                "PDFReaderCore-x86_64.abi.json",
            ],
        },
        "warningDisposition": {
            "linkerArchitectureWarnings": len(linker_warnings),
            "swiftActorIsolationWarnings": len(isolation_warnings),
            "unexpectedCompilerWarnings": len(other_compiler_warnings),
            "benignAppIntentsMetadataWarnings": app_intents_warnings,
        },
    }
    (EVIDENCE / "report.json").write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print(json.dumps(report, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
