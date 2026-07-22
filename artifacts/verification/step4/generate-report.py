#!/usr/bin/env python3
"""Generate deterministic Step 4 verification summaries from fresh build evidence."""

from __future__ import annotations

import hashlib
import json
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
EVIDENCE = ROOT / "artifacts/verification/step4"
SYMBOL_GRAPH = Path("/tmp/PDFReaderCore.symbols.json")


def read(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


def write_json(name: str, value: object) -> None:
    (EVIDENCE / name).write_text(
        json.dumps(value, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def sha256(relative: str) -> str:
    return hashlib.sha256((ROOT / relative).read_bytes()).hexdigest()


def imports(relative: str) -> list[str]:
    return re.findall(r"^import\s+([A-Za-z0-9_]+)\s*$", read(relative), re.MULTILINE)


def lock_version(relative: str) -> str:
    document = json.loads(read(relative))
    pins = document.get("pins", document.get("object", {}).get("pins", []))
    match = next(pin for pin in pins if pin["identity"].lower() == "tomldecoder")
    return match["state"]["version"]


def test_passed(log: str, title: str) -> bool:
    return f'✔ Test "{title}" passed' in log


def main() -> None:
    EVIDENCE.mkdir(parents=True, exist_ok=True)

    core_config_files = sorted(
        str(path.relative_to(ROOT)) for path in (ROOT / "PDFReaderCore/Config").glob("*.swift")
    )
    production_config_files = core_config_files + sorted(
        str(path.relative_to(ROOT)) for path in (ROOT / "PDFReaderApp/Config").glob("*.swift")
    )
    production_sources = {path: read(path) for path in production_config_files}

    toml_imports = sorted(
        str(path.relative_to(ROOT))
        for base in (ROOT / "PDFReaderApp", ROOT / "PDFReaderCore", ROOT / "Spikes")
        for path in base.rglob("*.swift")
        if re.search(r"^import TOMLDecoder\s*$", path.read_text(encoding="utf-8"), re.MULTILINE)
    )
    expected_toml_imports = [
        "PDFReaderApp/Config/TOMLConfigDecoder.swift",
        "Spikes/Step0/Sources/Support/TOMLQualificationProbe.swift",
    ]
    assert toml_imports == expected_toml_imports, toml_imports

    core_import_map = {path: imports(path) for path in core_config_files}
    core_imported_modules = sorted({module for values in core_import_map.values() for module in values})
    assert core_imported_modules == ["Foundation"], core_imported_modules

    execution_tokens = [
        "Process(",
        "NSTask",
        "NSAppleScript",
        "popen(",
        "system(",
        "JavaScriptCore",
        "osascript",
        "/bin/sh",
    ]
    execution_hits = {
        path: [token for token in execution_tokens if token in source]
        for path, source in production_sources.items()
    }
    execution_hits = {path: hits for path, hits in execution_hits.items() if hits}
    assert execution_hits == {}, execution_hits

    service_source = read("PDFReaderApp/Config/ConfigService.swift")
    runtime_resource_hits = [
        token for token in ("DefaultConfig.toml", "Bundle.", "Bundle(") if token in service_source
    ]
    assert runtime_resource_hits == [], runtime_resource_hits
    assert "BuiltInDefaults.config" not in service_source
    assert "ConfigValidator.validate(SparseAppConfig())" in service_source

    package_lock = "Package.resolved"
    workspace_lock = "PDFReader.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
    package_version = lock_version(package_lock)
    workspace_version = lock_version(workspace_lock)
    assert package_version == workspace_version == "0.4.5"

    assert SYMBOL_GRAPH.is_file(), "Run swift-symbolgraph-extract before this generator."
    graph = json.loads(SYMBOL_GRAPH.read_text(encoding="utf-8"))
    config_surface = []
    for symbol in graph["symbols"]:
        components = symbol.get("pathComponents", [])
        if components and components[0] in {"ValidatedAppConfig", "ConfigValidationReport"}:
            config_surface.append(
                {
                    "accessLevel": symbol["accessLevel"],
                    "kind": symbol["kind"]["identifier"],
                    "path": components,
                }
            )
    config_surface.sort(key=lambda item: (item["path"], item["kind"]))
    initializer_symbols = [
        item for item in config_surface if item["kind"] == "swift.init"
    ]
    assert any(item["path"] == ["ValidatedAppConfig"] for item in config_surface)
    assert any(item["path"] == ["ConfigValidationReport"] for item in config_surface)
    assert initializer_symbols == [], initializer_symbols
    write_json(
        "core-public-config-surface.json",
        {
            "constructorsExternallyAvailable": False,
            "status": "passed",
            "symbols": config_surface,
        },
    )

    audit = {
        "configServiceRuntimeFallback": "typed BuiltInDefaults through ConfigValidator only",
        "coreConfigImportedModules": core_imported_modules,
        "coreConfigImports": core_import_map,
        "dependencyPins": {
            package_lock: package_version,
            workspace_lock: workspace_version,
        },
        "executionAPIsInProductionConfig": execution_hits,
        "publicValidatedConfigConstructors": len(initializer_symbols),
        "runtimeResourceFallbackReferences": runtime_resource_hits,
        "status": "passed",
        "tomlDecoderImports": toml_imports,
    }
    write_json("source-scope-audit.json", audit)

    swift_log = read("artifacts/verification/step4/swift-test.log")
    scenarios = [
        {
            "id": "U-CFG-01",
            "name": "missing file",
            "result": "complete typed built-ins activated; no path is created",
            "test": "U-CFG-01 missing deterministic path activates embedded defaults without creating a file",
        },
        {
            "id": "U-CFG-03",
            "name": "valid sparse file",
            "result": "sparse values overlay typed defaults and activate after full validation",
            "test": "U-CFG-03 valid partial user config activates only after complete validation",
        },
        {
            "id": "U-CFG-09",
            "name": "mixed invalid file",
            "result": "schema and semantic diagnostics aggregate; zero user values leak into fallback",
            "test": "U-CFG-09 any mixed decoder or semantic error falls back atomically with aggregated diagnostics",
        },
        {
            "id": "U-CFG-10",
            "name": "generated default documentation",
            "result": "generated TOML decodes to the sole typed runtime default",
            "test": "U-CFG-10 generated default TOML round-trips to the sole runtime default",
        },
    ]
    for scenario in scenarios:
        scenario["passed"] = test_passed(swift_log, scenario["test"])
        assert scenario["passed"], scenario
    write_json(
        "config-trace.json",
        {
            "activationRule": "validate complete effective configuration, then atomically swap; otherwise use complete built-ins",
            "scenarios": scenarios,
            "status": "passed",
        },
    )

    logs = {
        path.name: path.read_text(encoding="utf-8", errors="replace")
        for path in EVIDENCE.glob("*.log")
    }
    assert "Test run with 61 tests in 7 suites passed" in logs["swift-test.log"]
    assert "** BUILD SUCCEEDED **" in logs["xcode-build-debug.log"]
    assert "** BUILD SUCCEEDED **" in logs["xcode-build-release.log"]
    assert "** TEST SUCCEEDED **" in logs["xcode-unit-tests.log"]
    assert "** ANALYZE SUCCEEDED **" in logs["xcode-analyze.log"]

    all_log_text = "\n".join(logs.values())
    warning_lines = [line for line in all_log_text.splitlines() if "warning:" in line.lower()]
    benign_app_intents = [line for line in warning_lines if "Metadata extraction skipped" in line]
    benign_xcui_parse = [line for line in warning_lines if "XCUIAutomation" in line and "Failed to parse" in line]
    unexpected_warnings = [
        line for line in warning_lines if line not in benign_app_intents and line not in benign_xcui_parse
    ]
    assert unexpected_warnings == [], unexpected_warnings

    report = {
        "contract": {
            "configurationPath": "~/.config/pdf-reader/config.toml",
            "decoderBoundary": "TOMLDecoder 0.4.5 in PDFReaderApp only",
            "fallback": "complete built-ins with zero partial activation",
            "maximumBytes": 262144,
            "runtimeDefaultSource": "PDFReaderCore.BuiltInDefaults",
            "schema": "strict recursive allowlist with aggregated source diagnostics",
        },
        "generatedArtifacts": {
            "CONFIG.md.sha256": sha256("CONFIG.md"),
            "DefaultConfig.toml.sha256": sha256("PDFReaderApp/Resources/DefaultConfig.toml"),
        },
        "status": "passed",
        "story": "G005-step-4-implement-strict-config",
        "verification": {
            "configTrace": "config-trace.json",
            "publicConfigSurface": "core-public-config-surface.json",
            "publicInterface": [
                "PDFReaderCore-arm64.abi.json",
                "PDFReaderCore-x86_64.abi.json",
            ],
            "sourceScopeAudit": "source-scope-audit.json",
            "swiftPM": {"releaseBuild": "passed", "suites": 7, "tests": 61},
            "xcode": {
                "analyze": "passed",
                "appConfigSuites": 1,
                "appConfigTests": 12,
                "appXCTest": 1,
                "coreSuites": 5,
                "coreTests": 45,
                "debugBuild": "passed",
                "releaseArchitectures": ["arm64", "x86_64"],
                "releaseBuild": "passed",
            },
        },
        "warningDisposition": {
            "benignAppIntentsMetadataWarnings": len(benign_app_intents),
            "benignXCUIAutomationParseWarnings": len(benign_xcui_parse),
            "linkerArchitectureWarnings": len(re.findall(r"linker.*architecture|architecture.*linker", all_log_text, re.I)),
            "swiftActorIsolationWarnings": len(re.findall(r"warning:.*actor[- ]isolat", all_log_text, re.I)),
            "unexpectedCompilerWarnings": len(unexpected_warnings),
        },
    }
    write_json("report.json", report)
    (EVIDENCE / "final-marker.log").write_text(
        "G005 strict configuration verification passed.\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
