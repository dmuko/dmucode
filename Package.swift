// swift-tools-version:6.0
import Foundation
import PackageDescription

// Built from vendor/ghostty with scripts/build-ghosttykit.sh. SwiftPM checks
// that a binary target exists even when nothing being built uses it, so the
// app is left out of the package while GhosttyKit is missing. That lets
// `swift test` run on a fresh clone: the tests need only dmucodeCore.
let ghosttyKit = "vendor/ghostty/macos/GhosttyKit.xcframework"
let hasGhosttyKit = FileManager.default.fileExists(atPath: Context.packageDirectory + "/" + ghosttyKit)

var targets: [Target] = [
    // The GhosttyKit-free part: the tmux wrapper and parsers, the session
    // store, the sidebar layout, fuzzy matching, `git status`.
    .target(name: "dmucodeCore"),
    // `swift test`: the parsers and the sidebar layout, through
    // @testable import of dmucodeCore. Needs no GhosttyKit.
    .testTarget(
        name: "dmucodeTests",
        dependencies: ["dmucodeCore"]
    ),
]

if hasGhosttyKit {
    targets += [
        .binaryTarget(name: "GhosttyKit", path: ghosttyKit),
        .executableTarget(
            name: "dmucode",
            dependencies: ["dmucodeCore", "GhosttyKit"],
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
    ]
}

let package = Package(
    name: "dmucode",
    platforms: [.macOS(.v14)],
    targets: targets,
    swiftLanguageModes: [.v5]
)
