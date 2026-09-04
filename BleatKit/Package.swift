// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "bleat",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "BleatKit", targets: ["BleatKit"]),
        .library(name: "BleatUI", targets: ["BleatUI"]),
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
        // macOS-only: spawns `herdr` as a child process. Deliberately NOT a
        // product — a library product carries no platform filter, so exporting
        // it would put "BleatProcess" in Xcode's picker for the iOS app and
        // reintroduce the very build failure this target exists to prevent.
        // Only `bleat`, which is macOS-only itself, depends on it.
        .target(name: "BleatProcess", dependencies: ["BleatKit"]),
        .target(name: "BleatUI", dependencies: ["BleatKit"]),
        .executableTarget(name: "bleat", dependencies: ["BleatKit", "BleatProcess"]),
        .testTarget(name: "BleatKitTests", dependencies: ["BleatKit"]),
    ]
)
