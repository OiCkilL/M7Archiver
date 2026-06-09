// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "M7Archiver",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "ArchiveCore", targets: ["ArchiveCore"]),
        .library(name: "ArchivePresentation", targets: ["ArchivePresentation"]),
        .executable(name: "M7ArchiverApp", targets: ["M7ArchiverApp"]),
        .executable(name: "QuickLookPreviewExtension", targets: ["QuickLookPreviewExtension"]),
        .executable(name: "QuickLookThumbnailExtension", targets: ["QuickLookThumbnailExtension"]),
        .executable(name: "FinderExtension", targets: ["FinderExtension"])
    ],
    targets: [
        .target(
            name: "CLibArchiveBridge",
            path: "Sources/CLibArchiveBridge",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("../../Vendor/libarchive/include")
            ],
            linkerSettings: [
                .unsafeFlags(["Vendor/libarchive/lib/libarchive.a"]),
                .linkedLibrary("z"),
                .linkedLibrary("bz2"),
                .linkedLibrary("iconv")
            ]
        ),
        .target(
            name: "CSevenZipBridge",
            path: "Sources/CSevenZipBridge",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("vendor/7zip/C"),
                .define("Z7_PPMD_SUPPORT"),
                .define("Z7_EXTRACT_ONLY"),
                .unsafeFlags(["-D_REENTRANT", "-D_FILE_OFFSET_BITS=64", "-D_LARGEFILE_SOURCE"])
            ]
        ),
        .target(
            name: "ArchiveCore",
            dependencies: ["CLibArchiveBridge", "CSevenZipBridge"],
            path: "Sources/ArchiveCore",
            resources: [
                .process("Formats/ArchiveFormatCatalog.json")
            ]
        ),
        .target(
            name: "ArchivePresentation",
            dependencies: ["ArchiveCore"],
            path: "Sources/ArchivePresentation"
        ),
        .executableTarget(
            name: "M7ArchiverApp",
            dependencies: ["ArchiveCore", "ArchivePresentation"],
            path: "Sources/M7ArchiverApp",
            exclude: ["M7ArchiverApp.entitlements", "Info.plist"]
        ),
        .executableTarget(
            name: "QuickLookPreviewExtension",
            dependencies: ["ArchiveCore", "ArchivePresentation"],
            path: "Extensions/QuickLookPreviewExtension",
            exclude: ["Info.plist", "QuickLookPreviewExtension.entitlements"],
            linkerSettings: [
                .linkedFramework("Quartz")
            ]
        ),
        .executableTarget(
            name: "QuickLookThumbnailExtension",
            dependencies: ["ArchiveCore"],
            path: "Extensions/QuickLookThumbnailExtension",
            exclude: ["Info.plist", "QuickLookThumbnailExtension.entitlements"],
            linkerSettings: [
                .linkedFramework("QuickLookThumbnailing")
            ]
        ),
        .executableTarget(
            name: "FinderExtension",
            dependencies: [],
            path: "Extensions/FinderExtension",
            exclude: ["Info.plist", "FinderExtension.entitlements"],
            linkerSettings: [
                .linkedFramework("FinderSync")
            ]
        ),
        .testTarget(
            name: "ArchiveCoreTests",
            dependencies: ["ArchiveCore"],
            path: "Tests/ArchiveCoreTests",
            exclude: ["FixtureGenerators"],
            resources: [
                .copy("Fixtures")
            ]
        ),
        .testTarget(
            name: "M7ArchiverAppTests",
            dependencies: ["M7ArchiverApp", "ArchiveCore", "ArchivePresentation"],
            path: "Tests/M7ArchiverAppTests"
        ),
        .testTarget(
            name: "QuickLookPreviewExtensionTests",
            dependencies: ["QuickLookPreviewExtension", "ArchiveCore"],
            path: "Tests/QuickLookPreviewExtensionTests"
        ),
        .testTarget(
            name: "FinderExtensionTests",
            dependencies: ["FinderExtension"],
            path: "Tests/FinderExtensionTests"
        )
    ]
)
