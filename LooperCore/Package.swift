// swift-tools-version: 6.0
// LooperCore: the processing engine (composition, export, audio).
// No UI frameworks here (no SwiftUI/AppKit), so it can be tested headless in CI
// and reused later (for example by a batch or command-line front end).

import PackageDescription

let package = Package(
    name: "LooperCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LooperCore", targets: ["LooperCore"]),
        .executable(name: "looper", targets: ["LooperCLI"]),
    ],
    targets: [
        .target(name: "LooperCore"),
        .executableTarget(name: "LooperCLI", dependencies: ["LooperCore"]),
        .testTarget(name: "LooperCoreTests", dependencies: ["LooperCore"]),
    ]
)
