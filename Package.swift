// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "bleat",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "BleatKit", targets: ["BleatKit"]),
        .executable(name: "bleat", targets: ["bleat"]),
    ],
    dependencies: [
        .package(url: "https://github.com/orlandos-nl/Citadel.git", from: "0.8.0"),
    ],
    targets: [
        .target(
            name: "BleatKit",
            dependencies: [.product(name: "Citadel", package: "Citadel")]
        ),
        .executableTarget(name: "bleat", dependencies: ["BleatKit"]),
        .testTarget(name: "BleatKitTests", dependencies: ["BleatKit"]),
    ]
)
