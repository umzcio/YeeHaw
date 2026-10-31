// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "YeeHaw",
    platforms: [.macOS("27.2")],
    targets: [
        .target(name: "YeeHawCore"),
        .executableTarget(name: "YeeHaw", dependencies: ["YeeHawCore"]),
        .testTarget(name: "YeeHawCoreTests", dependencies: ["YeeHawCore"]),
    ],
    swiftLanguageModes: [.v6]
)
