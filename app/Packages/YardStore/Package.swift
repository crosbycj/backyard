// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "YardStore",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [.library(name: "YardStore", targets: ["YardStore"])],
    dependencies: [
        .package(path: "../YardModel"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
    ],
    targets: [
        .target(name: "YardStore", dependencies: [
            "YardModel", .product(name: "GRDB", package: "GRDB.swift"),
        ]),
    ],
    swiftLanguageModes: [.v5]
)
