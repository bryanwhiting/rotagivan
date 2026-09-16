// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "ConfigurationYAML",
    platforms: [.macOS(.v13)],
    products: [.library(name: "ConfigurationYAML", type: .static, targets: ["ConfigurationYAML"])],
    dependencies: [.package(url: "https://github.com/jpsim/Yams.git", exact: "6.1.0")],
    targets: [.target(name: "ConfigurationYAML", dependencies: [.product(name: "Yams", package: "Yams")])]
)
