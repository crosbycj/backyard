// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "YardModel",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [.library(name: "YardModel", targets: ["YardModel"])],
    targets: [.target(name: "YardModel")],
    swiftLanguageModes: [.v5]
)
