// swift-tools-version: 6.2
import PackageDescription

// a developer tool, not part of the app. it times the two things the meetings
// work has to know before it is built: whether two sides of whisper large-v3
// keep up live, and how long the end of a long meeting takes.
let package = Package(
    name: "meeting-bench",
    platforms: [
        .macOS("26.0"),
    ],
    dependencies: [
        // the same pins as apps/mac/project.yml. move them together.
        .package(url: "https://github.com/FluidInference/FluidAudio", exact: "0.15.5"),
        .package(url: "https://github.com/argmaxinc/WhisperKit", exact: "1.1.0"),
    ],
    targets: [
        .executableTarget(
            name: "meeting-bench",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "WhisperKit", package: "WhisperKit"),
            ]
        ),
    ]
)
