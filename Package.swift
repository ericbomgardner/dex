// swift-tools-version: 6.0
import PackageDescription

// Rebuild & Restart is a release build, and whole-module recompiles every file beside
// the one you changed. SwiftPM leaves -incremental off in release, which does the same.
let incrementalRelease: [SwiftSetting] = [
    .unsafeFlags(["-no-whole-module-optimization", "-incremental"], .when(configuration: .release))
]

let package = Package(
    name: "Dex",
    platforms: [
        .macOS(.v15),
    ],
    targets: [
        .target(name: "DexCore", swiftSettings: incrementalRelease),

        // Everything the app draws, under the `main.swift` in `DexCode`.
        .target(
            name: "DexUI",
            dependencies: ["DexCore"],
            swiftSettings: incrementalRelease
        ),

        .executableTarget(
            name: "DexCode",
            dependencies: ["DexUI"],
            swiftSettings: incrementalRelease
        ),


        // The view probes, which stage the real views offscreen and read them.
        // Their own executable, so the app carries none of them.
        .executableTarget(
            name: "DexProbes",
            dependencies: ["DexUI"],
            swiftSettings: incrementalRelease
        ),

        // On the views as well as the core, for the one reading that is only in
        // the views: what a scroll view does when the pane shrinks under it.
        // `ScrollProbe` stages it; `TranscriptScrollTests` pins what it reads.
        .testTarget(
            name: "DexTests",
            dependencies: ["DexCore", "DexUI", "DexProbes"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
