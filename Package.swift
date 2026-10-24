// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Delta",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "DeltaApp", targets: ["DeltaApp"]),
        // Binary is "delta"; the app binary is "DeltaApp" so the two never collide on a case-insensitive disk.
        .executable(name: "delta", targets: ["DeltaCLI"]),
    ],
    targets: [
        .target(name: "DiffCore"),
        .executableTarget(
            name: "DeltaApp",
            dependencies: ["DiffCore"],
            // AppKit delegate/representable glue is main-thread by construction; Swift 5 mode avoids annotating every callback.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(name: "DeltaCLI", dependencies: ["DiffCore"]),
        .testTarget(name: "DiffCoreTests", dependencies: ["DiffCore"]),
    ]
)
