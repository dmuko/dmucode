// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "dmucode",
    platforms: [.macOS(.v14)],
    targets: [
        // Built from vendor/ghostty with scripts/build-ghosttykit.sh.
        .binaryTarget(
            name: "GhosttyKit",
            path: "vendor/ghostty/macos/GhosttyKit.xcframework"
        ),
        .executableTarget(
            name: "dmucode",
            dependencies: ["GhosttyKit"],
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreText"),
                .linkedFramework("IOSurface"),
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("UniformTypeIdentifiers"),
            ]
        ),
        // `swift test`: the parsers and the sidebar layout, through
        // @testable import of the app target.
        .testTarget(
            name: "dmucodeTests",
            dependencies: ["dmucode"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
