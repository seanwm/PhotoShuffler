// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PhotoShuffler",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PhotoShuffler", targets: ["PhotoShuffler"]),
    ],
    targets: [
        // Pure selection logic: no PhotoKit, fully unit-testable.
        .target(
            name: "ShufflerCore"
        ),
        // CLI + PhotoKit. All writes to the Photos library live in PhotoLibrary.swift.
        .executableTarget(
            name: "PhotoShuffler",
            dependencies: ["ShufflerCore"],
            linkerSettings: [
                .linkedFramework("Photos"),
                // Embed Info.plist in the binary too, so it carries
                // NSPhotoLibraryUsageDescription even outside the .app bundle.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Resources/Info.plist",
                ]),
            ]
        ),
        .testTarget(
            name: "ShufflerCoreTests",
            dependencies: ["ShufflerCore"]
        ),
    ]
)
