// swift-tools-version: 6.2
import PackageDescription

// a developer tool, not part of the app. it asks one question: does feeding
// audio to FluidAudio's sliding-window manager while it is recorded give the
// same words as transcribing the whole utterance at key-up?
let package = Package(
    name: "fidelity",
    platforms: [
        .macOS("26.0"),
    ],
    dependencies: [
        // the same pin as apps/mac/project.yml. move them together.
        .package(url: "https://github.com/FluidInference/FluidAudio", exact: "0.15.5"),
    ],
    targets: [
        .executableTarget(
            name: "fidelity",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),
    ]
)
