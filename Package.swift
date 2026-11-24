// swift-tools-version:5.9
import PackageDescription

let regex: [SwiftSetting] = [.enableUpcomingFeature("BareSlashRegexLiterals")]

let package = Package(
    name: "Crate",
    platforms: [.macOS(.v14)],
    targets: [
        // Everything that is not UI: library database, scanning, analysis,
        // the agent bridge and its tools. Kept separate so it can be tested.
        // The deck's audio-thread code, in C: no allocation, locks or Swift runtime while rendering.
        .target(name: "CrateDSP", path: "Sources/CrateDSP"),
        .target(
            name: "CrateCore",
            dependencies: ["CrateDSP"],
            path: "Sources/CrateCore",
            swiftSettings: regex,
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "Crate",
            dependencies: ["CrateCore"],
            path: "Sources/Crate",
            swiftSettings: regex
        ),
        .testTarget(
            name: "CrateCoreTests",
            dependencies: ["CrateCore"],
            path: "Tests/CrateCoreTests",
            swiftSettings: regex
        ),
    ]
)
