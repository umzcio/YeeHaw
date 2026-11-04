// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "YeeHaw",
    platforms: [.macOS("27.2")],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")],
    targets: [
        .target(name: "YeeHawCore"),
        .executableTarget(
            name: "YeeHaw",
            dependencies: ["YeeHawCore", .product(name: "Sparkle", package: "Sparkle")],
            // Sparkle.framework is copied into YeeHaw.app/Contents/Frameworks by scripts/build-app.sh.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "YeeHawCoreTests", dependencies: ["YeeHawCore"]),
        .testTarget(name: "YeeHawTests", dependencies: ["YeeHaw"]),
    ],
    swiftLanguageModes: [.v6]
)
