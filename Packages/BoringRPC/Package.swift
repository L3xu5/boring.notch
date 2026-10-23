// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BoringRPC",
    platforms: [.macOS(.v14)],
    products: [.library(name: "BoringRPC", type: .static, targets: ["BoringRPC"])],
    targets: [.target(name: "BoringRPC")],
    swiftLanguageModes: [.v6]
)
