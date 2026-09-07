// swift-tools-version: 6.2
import PackageDescription

/// Mirrors what the Xcode targets set, so a file behaves the same whichever
/// side of the seam compiles it. Keep this and the `.xcodeproj` in step: if
/// they drift, a `nonisolated func f() async` can run on a different executor
/// depending on which side compiled it.
///
/// `NonisolatedNonsendingByDefault` (the package half of
/// `SWIFT_APPROACHABLE_CONCURRENCY`) is deliberately **absent**, and the Xcode
/// targets leave that setting off to match. Enabling it reproducibly segfaults
/// the test bundle on Swift 6.3.3: `swift test` dies with signal 11, while
/// `swift test --no-parallel` passes all 70 and every suite passes on its own —
/// so it only bites under swift-testing's parallel execution. Turning it on for
/// the app alone would have been worse than leaving it off for both: the seam
/// would differ in exactly the way this comment exists to prevent.
///
/// Revisit on a newer toolchain; the feature is wanted, it just cannot be
/// enabled honestly today.
let sharedSwiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("MemberImportVisibility"),
]

let package = Package(
    name: "BleatKit",
    platforms: [.macOS(.v15), .iOS(.v18)],
    // Language mode is explicit rather than inherited from the tools version:
    // that setting is the one that silently lags (see sharedSwiftSettings).
    products: [
        .library(name: "BleatKit", targets: ["BleatKit"]),
        .library(name: "BleatUI", targets: ["BleatUI"]),
        .executable(name: "bleat", targets: ["bleat"]),
    ],
    dependencies: [
        .package(url: "https://github.com/orlandos-nl/Citadel.git", from: "0.8.0"),
        // A real VT100/xterm emulator, and the reason there is no hand-rolled
        // one: `terminal.frame` payloads carry cursor positioning and
        // synchronized-output markers *inside* the bytes, so anything that
        // approximated ANSI would render a Claude Code pane as nonsense.
        // Linked by BleatUI only — BleatKit stays free of rendering, and the
        // console tool writes the same bytes straight to a terminal that
        // already knows how to read them.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.20.0"),
    ],
    targets: [
        .target(
            name: "BleatKit",
            dependencies: [.product(name: "Citadel", package: "Citadel")],
            swiftSettings: sharedSwiftSettings
        ),
        // macOS-only: spawns `herdr` as a child process. Deliberately NOT a
        // product — a library product carries no platform filter, so exporting
        // it would put "BleatProcess" in Xcode's picker for the iOS app and
        // reintroduce the very build failure this target exists to prevent.
        // Only `bleat`, which is macOS-only itself, depends on it.
        .target(
            name: "BleatProcess",
            dependencies: ["BleatKit"],
            swiftSettings: sharedSwiftSettings
        ),
        // The only target that is MainActor-by-default. BleatKit deliberately
        // is not: it is a transport and domain library whose work belongs off
        // the main actor, and the console tool links it with no main actor in
        // sight. Isolation there is expressed per type, not inherited.
        .target(
            name: "BleatUI",
            dependencies: [
                "BleatKit",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            swiftSettings: sharedSwiftSettings + [.defaultIsolation(MainActor.self)]
        ),
        .executableTarget(
            name: "bleat",
            dependencies: ["BleatKit", "BleatProcess"],
            swiftSettings: sharedSwiftSettings
        ),
        // macOS-only, like the target it covers. `BleatProcess` compiles to
        // nothing on iOS, and so does this.
        .testTarget(
            name: "BleatProcessTests",
            dependencies: ["BleatProcess", "BleatKit"],
            swiftSettings: sharedSwiftSettings
        ),
        // **iOS-only, and it is the pane geometry it exists for.** The cell
        // arithmetic here has until now been verified by looking at a phone,
        // which is how several sizing bugs survived a green test run. It needs
        // a simulator destination:
        //   xcodebuild test -scheme bleat-Package \
        //     -destination 'platform=iOS Simulator,name=iPhone 16 Pro'
        .testTarget(
            name: "BleatUITests",
            dependencies: ["BleatUI", "BleatKit"],
            swiftSettings: sharedSwiftSettings + [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(
            name: "BleatKitTests",
            dependencies: ["BleatKit"],
            swiftSettings: sharedSwiftSettings
        ),
    ],
    swiftLanguageModes: [.v6]
)
