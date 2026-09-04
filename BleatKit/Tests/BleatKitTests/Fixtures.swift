import Foundation

/// Loads the captured `herdr` output in `Fixtures/`. No test touches the network.
enum Fixture {
    static let directory: URL = {
        URL(fileURLWithPath: #filePath)          // Tests/BleatKitTests/Fixtures.swift
            .deletingLastPathComponent()          // Tests/BleatKitTests
            .deletingLastPathComponent()          // Tests
            .deletingLastPathComponent()          // package root (BleatKit/)
            .appendingPathComponent("Fixtures")
    }()

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent(name))
    }
}
