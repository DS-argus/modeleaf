#!/usr/bin/env python3
"""Generate the small deterministic Xcode project without external tooling."""

from __future__ import annotations

import hashlib
import shutil
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PROJECT_DIR = ROOT / "PDFReader.xcodeproj"


def oid(name: str) -> str:
    return hashlib.sha1(name.encode("utf-8")).hexdigest()[:24].upper()


TARGETS = {
    "PDFReaderCore": {
        "product": "PDFReaderCore.framework",
        "file_type": "wrapper.framework",
        "product_type": "com.apple.product-type.framework",
        "bundle_id": "com.argus.pdfreader.core",
        "deps": [],
        "links": [],
        "package": False,
    },
    "PDFReaderApp": {
        "product": "PDFReader.app",
        "file_type": "wrapper.application",
        "product_type": "com.apple.product-type.application",
        "bundle_id": "com.argus.pdfreader",
        "deps": ["PDFReaderCore"],
        "links": ["PDFReaderCore"],
        "package": True,
    },
    "PDFReaderTestSupport": {
        "product": "PDFReaderTestSupport.framework",
        "file_type": "wrapper.framework",
        "product_type": "com.apple.product-type.framework",
        "bundle_id": "com.argus.pdfreader.testsupport",
        "deps": ["PDFReaderCore"],
        "links": ["PDFReaderCore"],
        "package": False,
    },
    "PDFReaderCoreTests": {
        "product": "PDFReaderCoreTests.xctest",
        "file_type": "wrapper.cfbundle",
        "product_type": "com.apple.product-type.bundle.unit-test",
        "bundle_id": "com.argus.pdfreader.coretests",
        "deps": ["PDFReaderCore"],
        "links": ["PDFReaderCore"],
        "package": False,
    },
    "PDFReaderAppTests": {
        "product": "PDFReaderAppTests.xctest",
        "file_type": "wrapper.cfbundle",
        "product_type": "com.apple.product-type.bundle.unit-test",
        "bundle_id": "com.argus.pdfreader.apptests",
        "deps": ["PDFReaderApp", "PDFReaderCore", "PDFReaderTestSupport"],
        "links": ["PDFReaderCore", "PDFReaderTestSupport"],
        "package": False,
    },
    "PDFReaderUITests": {
        "product": "PDFReaderUITests.xctest",
        "file_type": "wrapper.cfbundle",
        "product_type": "com.apple.product-type.bundle.ui-testing",
        "bundle_id": "com.argus.pdfreader.uitests",
        "deps": ["PDFReaderApp"],
        "links": [],
        "package": False,
    },
}


def target_id(name: str) -> str:
    return oid(f"target:{name}")


def product_ref(name: str) -> str:
    return oid(f"product:{name}")


def group_id(name: str) -> str:
    return oid(f"sync-group:{name}")


def exception_set_id(name: str) -> str:
    return oid(f"sync-group-exceptions:{name}")


def phase_id(name: str, phase: str) -> str:
    return oid(f"phase:{name}:{phase}")


def config_id(name: str, configuration: str) -> str:
    return oid(f"config:{name}:{configuration}")


def config_list_id(name: str) -> str:
    return oid(f"config-list:{name}")


PROJECT_ID = oid("project")
MAIN_GROUP_ID = oid("main-group")
PRODUCTS_GROUP_ID = oid("products-group")
PROJECT_CONFIG_LIST_ID = config_list_id("project")
PACKAGE_REF_ID = oid("package:TOMLDecoder")
PACKAGE_PRODUCT_ID = oid("package-product:TOMLDecoder")


def build_file_id(target: str, dependency: str) -> str:
    return oid(f"build-file:{target}:{dependency}")


def proxy_id(target: str, dependency: str) -> str:
    return oid(f"proxy:{target}:{dependency}")


def dependency_id(target: str, dependency: str) -> str:
    return oid(f"dependency:{target}:{dependency}")


def settings_lines(name: str, configuration: str) -> list[str]:
    target = TARGETS[name]
    lines = [
        f"PRODUCT_BUNDLE_IDENTIFIER = {target['bundle_id']};",
        "GENERATE_INFOPLIST_FILE = YES;",
        "SWIFT_VERSION = 6.0;",
        "SWIFT_STRICT_CONCURRENCY = complete;",
        "MACOSX_DEPLOYMENT_TARGET = 14.0;",
    ]
    product_type = target["product_type"]
    if product_type == "com.apple.product-type.application":
        lines.remove("GENERATE_INFOPLIST_FILE = YES;")
        lines += [
            "GENERATE_INFOPLIST_FILE = NO;",
            "INFOPLIST_FILE = PDFReaderApp/Info.plist;",
            "PRODUCT_NAME = PDFReader;",
            "PRODUCT_MODULE_NAME = PDFReaderApp;",
            "CODE_SIGN_STYLE = Automatic;",
            'LD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/../Frameworks";',
        ]
    elif product_type == "com.apple.product-type.framework":
        lines += [
            "DEFINES_MODULE = YES;",
            'DYLIB_INSTALL_NAME_BASE = "@rpath";',
            "SKIP_INSTALL = YES;",
            f"PRODUCT_NAME = {name};",
        ]
    elif product_type == "com.apple.product-type.bundle.unit-test":
        lines += [
            "PRODUCT_NAME = \"$(TARGET_NAME)\";",
            'LD_RUNPATH_SEARCH_PATHS = "$(inherited) @loader_path/Frameworks @loader_path/../Frameworks";',
        ]
        if name == "PDFReaderAppTests":
            lines += [
                'BUNDLE_LOADER = "$(TEST_HOST)";',
                'TEST_HOST = "$(BUILT_PRODUCTS_DIR)/PDFReader.app/Contents/MacOS/PDFReader";',
            ]
        else:
            lines.append('BUNDLE_LOADER = "";')
    else:
        lines += [
            "PRODUCT_NAME = \"$(TARGET_NAME)\";",
            "TEST_TARGET_NAME = PDFReaderApp;",
            'LD_RUNPATH_SEARCH_PATHS = "$(inherited) @loader_path/Frameworks @loader_path/../Frameworks";',
        ]
    if configuration == "Debug":
        lines.append('SWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG $(inherited)";')
    return lines


def generate_pbxproj() -> str:
    lines: list[str] = [
        "// !$*UTF8*$!",
        "{",
        "\tarchiveVersion = 1;",
        "\tclasses = {};",
        "\tobjectVersion = 77;",
        "\tobjects = {",
        "",
        "/* Begin PBXBuildFile section */",
    ]

    for target, data in TARGETS.items():
        for dep in data["links"]:
            lines.append(
                f"\t\t{build_file_id(target, dep)} /* {dep}.framework in Frameworks */ = "
                f"{{isa = PBXBuildFile; fileRef = {product_ref(dep)} /* {TARGETS[dep]['product']} */; }};"
            )
    lines.append(
        f"\t\t{build_file_id('PDFReaderApp', 'TOMLDecoder')} /* TOMLDecoder in Frameworks */ = "
        f"{{isa = PBXBuildFile; productRef = {PACKAGE_PRODUCT_ID} /* TOMLDecoder */; }};"
    )
    lines.append(
        f"\t\t{oid('embed:PDFReaderApp:PDFReaderCore')} /* PDFReaderCore.framework in Embed Frameworks */ = "
        f"{{isa = PBXBuildFile; fileRef = {product_ref('PDFReaderCore')} /* PDFReaderCore.framework */; "
        "settings = {ATTRIBUTES = (CodeSignOnCopy, RemoveHeadersOnCopy, ); }; };"
    )
    lines += ["/* End PBXBuildFile section */", "", "/* Begin PBXContainerItemProxy section */"]

    for target, data in TARGETS.items():
        for dep in data["deps"]:
            lines += [
                f"\t\t{proxy_id(target, dep)} /* PBXContainerItemProxy */ = {{",
                "\t\t\tisa = PBXContainerItemProxy;",
                f"\t\t\tcontainerPortal = {PROJECT_ID} /* Project object */;",
                "\t\t\tproxyType = 1;",
                f"\t\t\tremoteGlobalIDString = {target_id(dep)};",
                f"\t\t\tremoteInfo = {dep};",
                "\t\t};",
            ]
    lines += ["/* End PBXContainerItemProxy section */", "", "/* Begin PBXFileReference section */"]

    for name, data in TARGETS.items():
        lines.append(
            f"\t\t{product_ref(name)} /* {data['product']} */ = {{isa = PBXFileReference; "
            f"explicitFileType = {data['file_type']}; includeInIndex = 0; path = {data['product']}; sourceTree = BUILT_PRODUCTS_DIR; }};"
        )
    lines += [
        "/* End PBXFileReference section */",
        "",
        "/* Begin PBXFileSystemSynchronizedBuildFileExceptionSet section */",
        f"\t\t{exception_set_id('PDFReaderApp')} /* Exceptions for PDFReaderApp */ = {{",
        "\t\t\tisa = PBXFileSystemSynchronizedBuildFileExceptionSet;",
        "\t\t\tmembershipExceptions = (",
        "\t\t\t\tInfo.plist,",
        "\t\t\t);",
        f"\t\t\ttarget = {target_id('PDFReaderApp')} /* PDFReaderApp */;",
        "\t\t};",
        "/* End PBXFileSystemSynchronizedBuildFileExceptionSet section */",
        "",
        "/* Begin PBXCopyFilesBuildPhase section */",
        f"\t\t{phase_id('PDFReaderApp', 'embed-frameworks')} /* Embed Frameworks */ = {{",
        "\t\t\tisa = PBXCopyFilesBuildPhase;",
        "\t\t\tbuildActionMask = 2147483647;",
        "\t\t\tdstPath = \"\";",
        "\t\t\tdstSubfolderSpec = 10;",
        "\t\t\tfiles = (",
        f"\t\t\t\t{oid('embed:PDFReaderApp:PDFReaderCore')} /* PDFReaderCore.framework in Embed Frameworks */,",
        "\t\t\t);",
        "\t\t\tname = \"Embed Frameworks\";",
        "\t\t\trunOnlyForDeploymentPostprocessing = 0;",
        "\t\t};",
        "/* End PBXCopyFilesBuildPhase section */",
        "",
        "/* Begin PBXFileSystemSynchronizedRootGroup section */",
    ]

    for name in TARGETS:
        lines += [
            f"\t\t{group_id(name)} /* {name} */ = {{",
            "\t\t\tisa = PBXFileSystemSynchronizedRootGroup;",
        ]
        if name == "PDFReaderApp":
            lines += [
                "\t\t\texceptions = (",
                f"\t\t\t\t{exception_set_id(name)} /* Exceptions for PDFReaderApp */,",
                "\t\t\t);",
            ]
        lines += [
            f"\t\t\tpath = {name};",
            "\t\t\tsourceTree = \"<group>\";",
            "\t\t};",
        ]
    lines += ["/* End PBXFileSystemSynchronizedRootGroup section */", "", "/* Begin PBXFrameworksBuildPhase section */"]

    for name, data in TARGETS.items():
        lines += [
            f"\t\t{phase_id(name, 'frameworks')} /* Frameworks */ = {{",
            "\t\t\tisa = PBXFrameworksBuildPhase;",
            "\t\t\tbuildActionMask = 2147483647;",
            "\t\t\tfiles = (",
        ]
        for dep in data["links"]:
            lines.append(f"\t\t\t\t{build_file_id(name, dep)} /* {dep}.framework in Frameworks */,")
        if data["package"]:
            lines.append(f"\t\t\t\t{build_file_id(name, 'TOMLDecoder')} /* TOMLDecoder in Frameworks */,")
        lines += ["\t\t\t);", "\t\t\trunOnlyForDeploymentPostprocessing = 0;", "\t\t};"]
    lines += ["/* End PBXFrameworksBuildPhase section */", "", "/* Begin PBXGroup section */"]

    lines += [
        f"\t\t{MAIN_GROUP_ID} = {{",
        "\t\t\tisa = PBXGroup;",
        "\t\t\tchildren = (",
    ]
    for name in TARGETS:
        lines.append(f"\t\t\t\t{group_id(name)} /* {name} */,")
    lines += [
        f"\t\t\t\t{PRODUCTS_GROUP_ID} /* Products */,",
        "\t\t\t);",
        "\t\t\tsourceTree = \"<group>\";",
        "\t\t};",
        f"\t\t{PRODUCTS_GROUP_ID} /* Products */ = {{",
        "\t\t\tisa = PBXGroup;",
        "\t\t\tchildren = (",
    ]
    for name, data in TARGETS.items():
        lines.append(f"\t\t\t\t{product_ref(name)} /* {data['product']} */,")
    lines += [
        "\t\t\t);",
        "\t\t\tname = Products;",
        "\t\t\tsourceTree = \"<group>\";",
        "\t\t};",
        "/* End PBXGroup section */",
        "",
        "/* Begin PBXNativeTarget section */",
    ]

    for name, data in TARGETS.items():
        lines += [
            f"\t\t{target_id(name)} /* {name} */ = {{",
            "\t\t\tisa = PBXNativeTarget;",
            f"\t\t\tbuildConfigurationList = {config_list_id(name)} /* Build configuration list for PBXNativeTarget \"{name}\" */;",
            "\t\t\tbuildPhases = (",
            f"\t\t\t\t{phase_id(name, 'sources')} /* Sources */ ,",
            f"\t\t\t\t{phase_id(name, 'frameworks')} /* Frameworks */ ,",
            f"\t\t\t\t{phase_id(name, 'resources')} /* Resources */ ,",
        ]
        if name == "PDFReaderApp":
            lines.append(f"\t\t\t\t{phase_id(name, 'embed-frameworks')} /* Embed Frameworks */ ,")
        lines += [
            "\t\t\t);",
            "\t\t\tbuildRules = ();",
            "\t\t\tdependencies = (",
        ]
        for dep in data["deps"]:
            lines.append(f"\t\t\t\t{dependency_id(name, dep)} /* PBXTargetDependency */,")
        lines += [
            "\t\t\t);",
            "\t\t\tfileSystemSynchronizedGroups = (",
            f"\t\t\t\t{group_id(name)} /* {name} */,",
            "\t\t\t);",
            f"\t\t\tname = {name};",
            "\t\t\tpackageProductDependencies = (",
        ]
        if data["package"]:
            lines.append(f"\t\t\t\t{PACKAGE_PRODUCT_ID} /* TOMLDecoder */,")
        lines += [
            "\t\t\t);",
            f"\t\t\tproductName = {name};",
            f"\t\t\tproductReference = {product_ref(name)} /* {data['product']} */;",
            f"\t\t\tproductType = \"{data['product_type']}\";",
            "\t\t};",
        ]
    lines += ["/* End PBXNativeTarget section */", "", "/* Begin PBXProject section */"]

    lines += [
        f"\t\t{PROJECT_ID} /* Project object */ = {{",
        "\t\t\tisa = PBXProject;",
        "\t\t\tattributes = {",
        "\t\t\t\tBuildIndependentTargetsInParallel = 1;",
        "\t\t\t\tLastSwiftUpdateCheck = 2660;",
        "\t\t\t\tLastUpgradeCheck = 2660;",
        "\t\t\t};",
        f"\t\t\tbuildConfigurationList = {PROJECT_CONFIG_LIST_ID} /* Build configuration list for PBXProject \"PDFReader\" */;",
        "\t\t\tdevelopmentRegion = en;",
        "\t\t\thasScannedForEncodings = 0;",
        "\t\t\tknownRegions = (en, Base);",
        f"\t\t\tmainGroup = {MAIN_GROUP_ID};",
        "\t\t\tminimizedProjectReferenceProxies = 1;",
        "\t\t\tpackageReferences = (",
        f"\t\t\t\t{PACKAGE_REF_ID} /* XCRemoteSwiftPackageReference \"TOMLDecoder\" */,",
    ]
    lines += [
        "\t\t\t);",
        "\t\t\tpreferredProjectObjectVersion = 77;",
        f"\t\t\tproductRefGroup = {PRODUCTS_GROUP_ID} /* Products */;",
        "\t\t\tprojectDirPath = \"\";",
        "\t\t\tprojectRoot = \"\";",
        "\t\t\ttargets = (",
    ]
    for name in TARGETS:
        lines.append(f"\t\t\t\t{target_id(name)} /* {name} */,")
    lines += ["\t\t\t);", "\t\t};", "/* End PBXProject section */", ""]

    for phase_name, isa in [("resources", "PBXResourcesBuildPhase"), ("sources", "PBXSourcesBuildPhase")]:
        lines.append(f"/* Begin {isa} section */")
        for name in TARGETS:
            lines += [
                f"\t\t{phase_id(name, phase_name)} /* {phase_name.title()} */ = {{",
                f"\t\t\tisa = {isa};",
                "\t\t\tbuildActionMask = 2147483647;",
                "\t\t\tfiles = ();",
                "\t\t\trunOnlyForDeploymentPostprocessing = 0;",
                "\t\t};",
            ]
        lines.append(f"/* End {isa} section */")
        lines.append("")

    lines.append("/* Begin PBXTargetDependency section */")
    for name, data in TARGETS.items():
        for dep in data["deps"]:
            lines += [
                f"\t\t{dependency_id(name, dep)} /* PBXTargetDependency */ = {{",
                "\t\t\tisa = PBXTargetDependency;",
                f"\t\t\ttarget = {target_id(dep)} /* {dep} */;",
                f"\t\t\ttargetProxy = {proxy_id(name, dep)} /* PBXContainerItemProxy */;",
                "\t\t};",
            ]
    lines += ["/* End PBXTargetDependency section */", "", "/* Begin XCBuildConfiguration section */"]

    project_common = [
        "ALWAYS_SEARCH_USER_PATHS = NO;",
        "CLANG_ENABLE_MODULES = YES;",
        "CLANG_ENABLE_OBJC_ARC = YES;",
        "COPY_PHASE_STRIP = NO;",
        "ENABLE_STRICT_OBJC_MSGSEND = YES;",
        "ENABLE_USER_SCRIPT_SANDBOXING = YES;",
        "GCC_C_LANGUAGE_STANDARD = gnu17;",
        "MACOSX_DEPLOYMENT_TARGET = 14.0;",
        "SDKROOT = macosx;",
        "SWIFT_VERSION = 6.0;",
    ]
    for configuration in ["Debug", "Release"]:
        lines += [
            f"\t\t{config_id('project', configuration)} /* {configuration} */ = {{",
            "\t\t\tisa = XCBuildConfiguration;",
            "\t\t\tbuildSettings = {",
        ]
        for setting in project_common:
            lines.append(f"\t\t\t\t{setting}")
        if configuration == "Debug":
            lines += [
                "\t\t\t\tDEBUG_INFORMATION_FORMAT = dwarf;",
                "\t\t\t\tENABLE_TESTABILITY = YES;",
                "\t\t\t\tONLY_ACTIVE_ARCH = YES;",
                "\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = \"-Onone\";",
            ]
        else:
            lines += ["\t\t\t\tDEBUG_INFORMATION_FORMAT = \"dwarf-with-dsym\";", "\t\t\t\tSWIFT_COMPILATION_MODE = wholemodule;"]
        lines += ["\t\t\t};", f"\t\t\tname = {configuration};", "\t\t};"]

    for name in TARGETS:
        for configuration in ["Debug", "Release"]:
            lines += [
                f"\t\t{config_id(name, configuration)} /* {configuration} */ = {{",
                "\t\t\tisa = XCBuildConfiguration;",
                "\t\t\tbuildSettings = {",
            ]
            for setting in settings_lines(name, configuration):
                lines.append(f"\t\t\t\t{setting}")
            lines += ["\t\t\t};", f"\t\t\tname = {configuration};", "\t\t};"]
    lines += ["/* End XCBuildConfiguration section */", "", "/* Begin XCConfigurationList section */"]

    lines += [
        f"\t\t{PROJECT_CONFIG_LIST_ID} /* Build configuration list for PBXProject \"PDFReader\" */ = {{",
        "\t\t\tisa = XCConfigurationList;",
        f"\t\t\tbuildConfigurations = ({config_id('project', 'Debug')} /* Debug */, {config_id('project', 'Release')} /* Release */);",
        "\t\t\tdefaultConfigurationIsVisible = 0;",
        "\t\t\tdefaultConfigurationName = Release;",
        "\t\t};",
    ]
    for name in TARGETS:
        lines += [
            f"\t\t{config_list_id(name)} /* Build configuration list for PBXNativeTarget \"{name}\" */ = {{",
            "\t\t\tisa = XCConfigurationList;",
            f"\t\t\tbuildConfigurations = ({config_id(name, 'Debug')} /* Debug */, {config_id(name, 'Release')} /* Release */);",
            "\t\t\tdefaultConfigurationIsVisible = 0;",
            "\t\t\tdefaultConfigurationName = Release;",
            "\t\t};",
        ]
    lines += ["/* End XCConfigurationList section */", "", "/* Begin XCRemoteSwiftPackageReference section */"]

    lines += [
        f"\t\t{PACKAGE_REF_ID} /* XCRemoteSwiftPackageReference \"TOMLDecoder\" */ = {{",
        "\t\t\tisa = XCRemoteSwiftPackageReference;",
        "\t\t\trepositoryURL = \"https://github.com/dduan/TOMLDecoder.git\";",
        "\t\t\trequirement = {",
        "\t\t\t\tkind = exactVersion;",
        "\t\t\t\tversion = 0.4.5;",
        "\t\t\t};",
        "\t\t};",
        "/* End XCRemoteSwiftPackageReference section */",
        "",
        "/* Begin XCSwiftPackageProductDependency section */",
        f"\t\t{PACKAGE_PRODUCT_ID} /* TOMLDecoder */ = {{",
        "\t\t\tisa = XCSwiftPackageProductDependency;",
        f"\t\t\tpackage = {PACKAGE_REF_ID} /* XCRemoteSwiftPackageReference \"TOMLDecoder\" */;",
        "\t\t\tproductName = TOMLDecoder;",
        "\t\t};",
        "/* End XCSwiftPackageProductDependency section */",
        "\t};",
        f"\trootObject = {PROJECT_ID} /* Project object */;",
        "}",
        "",
    ]
    return "\n".join(lines)


def generate_scheme() -> str:
    build_entries = []
    for name in TARGETS:
        build_entries.append(f'''         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "{'YES' if name == 'PDFReaderApp' else 'NO'}"
            buildForProfiling = "{'YES' if name == 'PDFReaderApp' else 'NO'}"
            buildForArchiving = "{'YES' if name == 'PDFReaderApp' else 'NO'}"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{target_id(name)}"
               BuildableName = "{TARGETS[name]['product']}"
               BlueprintName = "{name}"
               ReferencedContainer = "container:PDFReader.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>''')

    testables = []
    for name in ["PDFReaderCoreTests", "PDFReaderAppTests", "PDFReaderUITests"]:
        testables.append(f'''         <TestableReference skipped = "NO">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{target_id(name)}"
               BuildableName = "{TARGETS[name]['product']}"
               BlueprintName = "{name}"
               ReferencedContainer = "container:PDFReader.xcodeproj">
            </BuildableReference>
         </TestableReference>''')

    app_ref = f'''      <BuildableReference
         BuildableIdentifier = "primary"
         BlueprintIdentifier = "{target_id('PDFReaderApp')}"
         BuildableName = "PDFReader.app"
         BlueprintName = "PDFReaderApp"
         ReferencedContainer = "container:PDFReader.xcodeproj">
      </BuildableReference>'''

    return f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "2660" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
{chr(10).join(build_entries)}
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv = "YES">
      <MacroExpansion>
{app_ref}
      </MacroExpansion>
      <Testables>
{chr(10).join(testables)}
      </Testables>
   </TestAction>
   <LaunchAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle = "0" useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES" debugServiceExtension = "internal" allowLocationSimulation = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
{app_ref}
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction buildConfiguration = "Release" shouldUseLaunchSchemeArgsEnv = "YES" savedToolIdentifier = "" useCustomWorkingDirectory = "NO" debugDocumentVersioning = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
{app_ref}
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction buildConfiguration = "Debug" />
   <ArchiveAction buildConfiguration = "Release" revealArchiveInOrganizer = "YES" />
</Scheme>
'''


def main() -> None:
    PROJECT_DIR.mkdir(exist_ok=True)
    (PROJECT_DIR / "project.pbxproj").write_text(generate_pbxproj(), encoding="utf-8")
    scheme_dir = PROJECT_DIR / "xcshareddata" / "xcschemes"
    scheme_dir.mkdir(parents=True, exist_ok=True)
    (scheme_dir / "PDFReader.xcscheme").write_text(generate_scheme(), encoding="utf-8")
    package_lock = ROOT / "Package.resolved"
    if package_lock.exists():
        swiftpm_dir = PROJECT_DIR / "project.xcworkspace" / "xcshareddata" / "swiftpm"
        swiftpm_dir.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(package_lock, swiftpm_dir / "Package.resolved")
    print("generated PDFReader.xcodeproj")


if __name__ == "__main__":
    main()
