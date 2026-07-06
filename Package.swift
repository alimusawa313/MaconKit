// swift-tools-version: 6.0
import PackageDescription

// Shared core for MacON, consumed by both the SwiftUI app and the `macon` CLI.
// No external dependencies, so it builds offline and is trivial to ship via brew.
let package = Package(
    name: "MaconKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MaconKit", targets: ["MaconKit"]),
        .executable(name: "macon", targets: ["macon"]),
    ],
    targets: [
        .target(
            name: "MaconKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "macon",
            dependencies: ["MaconKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
