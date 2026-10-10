// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Docklane",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Docklane", targets: ["Docklane"]),
        .library(name: "DocklaneCore", targets: ["DocklaneCore"]),
    ],
    targets: [
        // Window discovery, capture, focus and layout logic. No UI.
        .target(
            name: "DocklaneCore",
            path: "Sources/DocklaneCore"
        ),
        // The menu bar app: panels, settings, onboarding.
        .executableTarget(
            name: "Docklane",
            dependencies: ["DocklaneCore"],
            path: "Sources/Docklane"
        ),
        .testTarget(
            name: "DocklaneCoreTests",
            dependencies: ["DocklaneCore"],
            path: "Tests/DocklaneCoreTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
