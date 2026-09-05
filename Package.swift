// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Modeleaf",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "PDFReaderCore", targets: ["PDFReaderCore"]),
        .library(name: "PDFReaderTestSupport", targets: ["PDFReaderTestSupport"]),
        .executable(name: "Modeleaf", targets: ["PDFReaderApp"]),
        .executable(name: "ModeleafCLI", targets: ["ModeleafCLI"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/dduan/TOMLDecoder.git",
            exact: "0.4.5"
        ),
    ],
    targets: [
        .target(
            name: "PDFReaderCore",
            path: "PDFReaderCore"
        ),
        .executableTarget(
            name: "ModeleafCLI",
            path: "ModeleafCLI"
        ),
        .executableTarget(
            name: "PDFReaderApp",
            dependencies: [
                "PDFReaderCore",
                .product(name: "TOMLDecoder", package: "TOMLDecoder"),
            ],
            path: "PDFReaderApp",
            exclude: ["Info.plist", "Theme/ThemeAttributions.md"],
            resources: [.process("Resources")]
        ),
        .target(
            name: "PDFReaderTestSupport",
            dependencies: ["PDFReaderCore"],
            path: "PDFReaderTestSupport"
        ),
        .testTarget(
            name: "PDFReaderCoreTests",
            dependencies: ["PDFReaderCore"],
            path: "PDFReaderCoreTests",
            exclude: ["Snapshots"]
        ),
        .testTarget(
            name: "ModeleafCLITests",
            dependencies: ["ModeleafCLI"],
            path: "ModeleafCLITests"
        ),
        .testTarget(
            name: "PDFReaderAppTests",
            dependencies: ["PDFReaderApp", "PDFReaderCore", "PDFReaderTestSupport"],
            path: "PDFReaderAppTests"
        ),
    ]
)
