// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "bleat",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "BleatKit", targets: ["BleatKit"]),
        .executable(name: "bleat", targets: ["bleat"]),
    ],
    targets: [
        .target(name: "BleatKit"),
        .executableTarget(name: "bleat", dependencies: ["BleatKit"]),
        .testTarget(name: "BleatKitTests", dependencies: ["BleatKit"]),
    ]
)
