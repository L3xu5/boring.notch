// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BoringCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "BoringCore", type: .static, targets: ["BoringCore"])],
    targets: [
        .target(name: "BoringCore"),
        .testTarget(name: "BoringCoreTests", dependencies: ["BoringCore"]),
    ],
    swiftLanguageModes: [.v6]
)
