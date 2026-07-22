#!/usr/bin/env python3
"""Validate the generated Xcode graph using only macOS system tools."""

from __future__ import annotations

import json
import subprocess
import xml.etree.ElementTree as ET
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "PDFReader.xcodeproj"
PBXPROJ = PROJECT / "project.pbxproj"
SCHEME = PROJECT / "xcshareddata" / "xcschemes" / "PDFReader.xcscheme"
LOCK = PROJECT / "project.xcworkspace" / "xcshareddata" / "swiftpm" / "Package.resolved"

EXPECTED_TARGETS = {
    "PDFReaderCore": "com.apple.product-type.framework",
    "PDFReaderApp": "com.apple.product-type.application",
    "PDFReaderTestSupport": "com.apple.product-type.framework",
    "PDFReaderCoreTests": "com.apple.product-type.bundle.unit-test",
    "PDFReaderAppTests": "com.apple.product-type.bundle.unit-test",
    "PDFReaderUITests": "com.apple.product-type.bundle.ui-testing",
}


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def load_project() -> dict[str, object]:
    result = subprocess.run(
        ["plutil", "-convert", "json", "-o", "-", str(PBXPROJ)],
        check=True,
        capture_output=True,
        text=True,
    )
    return json.loads(result.stdout)


def validate_references(objects: dict[str, dict[str, object]], root_id: str) -> None:
    single_references = {
        "PBXProject": ["buildConfigurationList", "mainGroup", "productRefGroup"],
        "PBXNativeTarget": ["buildConfigurationList", "productReference"],
        "PBXTargetDependency": ["target", "targetProxy"],
        "PBXContainerItemProxy": ["containerPortal", "remoteGlobalIDString"],
        "PBXBuildFile": ["fileRef", "productRef"],
        "PBXFileSystemSynchronizedBuildFileExceptionSet": ["target"],
        "XCSwiftPackageProductDependency": ["package"],
    }
    list_references = {
        "PBXProject": ["packageReferences", "targets"],
        "PBXNativeTarget": [
            "buildPhases",
            "dependencies",
            "fileSystemSynchronizedGroups",
            "packageProductDependencies",
        ],
        "PBXGroup": ["children"],
        "PBXFrameworksBuildPhase": ["files"],
        "PBXCopyFilesBuildPhase": ["files"],
        "PBXSourcesBuildPhase": ["files"],
        "PBXResourcesBuildPhase": ["files"],
        "PBXFileSystemSynchronizedRootGroup": ["exceptions"],
        "XCConfigurationList": ["buildConfigurations"],
    }

    require(root_id in objects, f"rootObject {root_id} is missing")
    require(objects[root_id].get("isa") == "PBXProject", "rootObject is not PBXProject")

    for object_id, value in objects.items():
        isa = str(value.get("isa", ""))
        for key in single_references.get(isa, []):
            reference = value.get(key)
            if reference is not None:
                require(reference in objects, f"{object_id}.{key} references missing {reference}")
        for key in list_references.get(isa, []):
            for reference in value.get(key, []):
                require(reference in objects, f"{object_id}.{key} references missing {reference}")


def main() -> None:
    project = load_project()
    objects = project["objects"]
    require(isinstance(objects, dict), "objects must be a dictionary")
    validate_references(objects, str(project["rootObject"]))

    targets = {
        value["name"]: value
        for value in objects.values()
        if value.get("isa") == "PBXNativeTarget"
    }
    require(set(targets) == set(EXPECTED_TARGETS), f"unexpected target set: {sorted(targets)}")
    for name, product_type in EXPECTED_TARGETS.items():
        require(targets[name].get("productType") == product_type, f"{name} has wrong product type")

    app_phases = [objects[phase_id] for phase_id in targets["PDFReaderApp"]["buildPhases"]]
    embed_phases = [phase for phase in app_phases if phase.get("isa") == "PBXCopyFilesBuildPhase"]
    require(len(embed_phases) == 1, "PDFReaderApp must have one Embed Frameworks phase")
    require(embed_phases[0].get("dstSubfolderSpec") == "10", "Embed Frameworks destination is invalid")

    package_refs = [
        value for value in objects.values() if value.get("isa") == "XCRemoteSwiftPackageReference"
    ]
    require(len(package_refs) == 1, "expected exactly one Swift package")
    package = package_refs[0]
    require(package.get("repositoryURL") == "https://github.com/dduan/TOMLDecoder.git", "wrong package URL")
    require(
        package.get("requirement") == {"kind": "exactVersion", "version": "0.4.5"},
        "TOMLDecoder must be exact-pinned to 0.4.5",
    )

    build_configs = [value for value in objects.values() if value.get("isa") == "XCBuildConfiguration"]
    project_config_list = objects[objects[str(project["rootObject"])]["buildConfigurationList"]]
    project_configs = [objects[config_id] for config_id in project_config_list["buildConfigurations"]]
    debug_project_config = next(config for config in project_configs if config.get("name") == "Debug")
    require(
        debug_project_config["buildSettings"].get("ONLY_ACTIVE_ARCH") == "YES",
        "Debug builds must use only the active architecture",
    )
    target_configs = [value for value in build_configs if "PRODUCT_BUNDLE_IDENTIFIER" in value.get("buildSettings", {})]
    require(len(target_configs) == 12, "each of six targets must have Debug and Release configurations")
    for config in target_configs:
        settings = config["buildSettings"]
        require(settings.get("SWIFT_VERSION") == "6.0", "target does not use Swift 6")
        require(settings.get("SWIFT_STRICT_CONCURRENCY") == "complete", "strict concurrency is not complete")
        require(settings.get("MACOSX_DEPLOYMENT_TARGET") == "14.0", "deployment target is not macOS 14")

    core_config_list = objects[targets["PDFReaderCore"]["buildConfigurationList"]]
    for config_id in core_config_list["buildConfigurations"]:
        settings = objects[config_id]["buildSettings"]
        require(
            settings.get("DYLIB_INSTALL_NAME_BASE") == "@rpath",
            "PDFReaderCore must use an app-embeddable @rpath install name",
        )

    app_config_list = objects[targets["PDFReaderApp"]["buildConfigurationList"]]
    for config_id in app_config_list["buildConfigurations"]:
        settings = objects[config_id]["buildSettings"]
        require(
            settings.get("PRODUCT_MODULE_NAME") == "PDFReaderApp",
            "PDFReaderApp must expose one module name across SwiftPM and Xcode",
        )
        require(settings.get("GENERATE_INFOPLIST_FILE") == "NO", "PDFReaderApp must use its checked-in Info.plist")
        require(settings.get("INFOPLIST_FILE") == "PDFReaderApp/Info.plist", "PDFReaderApp Info.plist path is invalid")

    app_target_id = next(
        object_id for object_id, value in objects.items() if value is targets["PDFReaderApp"]
    )
    app_sync_group_id = targets["PDFReaderApp"]["fileSystemSynchronizedGroups"][0]
    app_sync_group = objects[app_sync_group_id]
    exception_ids = app_sync_group.get("exceptions", [])
    require(len(exception_ids) == 1, "PDFReaderApp must have one synchronized-group exception set")
    exception_set = objects[exception_ids[0]]
    require(exception_set.get("target") == app_target_id, "PDFReaderApp exception set must target PDFReaderApp")
    require(exception_set.get("membershipExceptions") == ["Info.plist"], "Info.plist must be excluded from synchronized target membership")

    scheme = ET.parse(SCHEME).getroot()
    require(scheme.tag == "Scheme", "shared scheme XML root is invalid")
    scheme_text = SCHEME.read_text(encoding="utf-8")
    for name in EXPECTED_TARGETS:
        require(f'BlueprintName = "{name}"' in scheme_text, f"shared scheme omits {name}")

    lock = json.loads(LOCK.read_text(encoding="utf-8"))
    pins = {pin["identity"]: pin for pin in lock["pins"]}
    require(pins["tomldecoder"]["state"]["version"] == "0.4.5", "workspace lock is not 0.4.5")

    print(
        json.dumps(
            {
                "status": "passed",
                "targets": sorted(targets),
                "swift": "6.0",
                "strictConcurrency": "complete",
                "deploymentTarget": "14.0",
                "frameworkInstallName": "@rpath",
                "appModuleName": "PDFReaderApp",
                "debugArchitectures": "active only",
                "dependency": "TOMLDecoder@0.4.5 exact",
                "sharedScheme": str(SCHEME.relative_to(ROOT)),
            },
            indent=2,
            sort_keys=True,
        )
    )


if __name__ == "__main__":
    main()
