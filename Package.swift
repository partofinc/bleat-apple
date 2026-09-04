// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "bleat",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "BleatKit", targets: ["BleatKit"]),
        // macOS-only: spawns `herdr` as a child process. Kept out of BleatKit
        // so the library still builds for iOS, where Foundation has no Process.
        .library(name: "BleatProcess", targets: ["BleatProcess"]),
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
        .target(name: "BleatProcess", dependencies: ["BleatKit"]),
        .executableTarget(name: "bleat", dependencies: ["BleatKit", "BleatProcess"]),
        .testTarget(name: "BleatKitTests", dependencies: ["BleatKit"]),
    ]
)
