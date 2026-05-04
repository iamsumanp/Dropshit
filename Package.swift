// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ShelfDemo",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.4"),
    ],
    targets: [
        .executableTarget(
            name: "ShelfDemo",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/ShelfDemo",
            // The .icns is consumed only by the packaged .app bundle (copied
            // by scripts/build-dmg.sh). Excluding it here keeps SwiftPM
            // quiet and avoids embedding it in the SPM module's bundle.
            exclude: ["Resources/AppIcon.icns"],
            resources: [
                .process("Resources"),
            ]
        ),
        .testTarget(
            name: "ShelfDemoTests",
            dependencies: ["ShelfDemo"],
            path: "Tests/ShelfDemoTests"
        ),
    ]
)
