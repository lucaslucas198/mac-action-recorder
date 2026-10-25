// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacActionRecorder",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "MacActionRecorder", targets: ["MacActionRecorder"]),
        .library(name: "MacActionRecorderCore", targets: ["MacActionRecorderCore"])
    ],
    targets: [
        // Platform-independent logic: data model, validation, timing, playback
        // scheduling, storage and settings. Foundation only, so it is unit-testable.
        .target(
            name: "MacActionRecorderCore"
        ),
        // The macOS application: SwiftUI interface, CGEvent recording and playback.
        .executableTarget(
            name: "MacActionRecorder",
            dependencies: ["MacActionRecorderCore"]
        ),
        .testTarget(
            name: "MacActionRecorderCoreTests",
            dependencies: ["MacActionRecorderCore"]
        )
    ]
)
