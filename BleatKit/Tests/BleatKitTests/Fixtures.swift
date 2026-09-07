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

    /// The same bytes as text, for the fixtures that are command output rather
    /// than JSON — `ifconfig.txt`, `localhostname.txt` — and for feeding a fake
    /// shell that answers with what a host really said.
    static func text(_ name: String) throws -> String {
        String(decoding: try data(name), as: UTF8.self)
    }
}
