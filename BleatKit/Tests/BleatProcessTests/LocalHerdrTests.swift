#if !os(iOS)
import BleatProcess
import Foundation
import Testing

@Suite("Finding the local herdr")
struct LocalHerdrTests {
    /// A directory holding an executable `herdr`, and one holding nothing.
    private func directories() throws -> (withHerdr: URL, empty: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-herdr-\(UUID().uuidString)")
        let bin = root.appendingPathComponent("bin"), empty = root.appendingPathComponent("empty")
        for directory in [bin, empty] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let herdr = bin.appendingPathComponent("herdr")
        try Data("#!/bin/sh\n".utf8).write(to: herdr)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: herdr.path)
        return (bin, empty)
    }

    @Test("PATH is searched before a login shell is started")
    func pathFirst() throws {
        let (bin, empty) = try directories()
        var askedShell = false
        let found = LocalHerdr.resolve(nil, path: "\(empty.path):\(bin.path)") {
            askedShell = true
            return "/from/the/shell"
        }
        #expect(found == bin.appendingPathComponent("herdr").path)
        #expect(!askedShell)
    }

    @Test("a login shell answers when PATH has no herdr")
    func shellFallback() throws {
        let (_, empty) = try directories()
        #expect(LocalHerdr.resolve(nil, path: empty.path) { "/from/the/shell" } == "/from/the/shell")
    }

    @Test("--herdr with a bare name is looked up on PATH, not in the working directory")
    func bareName() throws {
        let (bin, empty) = try directories()
        #expect(LocalHerdr.resolve("herdr", path: bin.path) { nil } == bin.appendingPathComponent("herdr").path)
        #expect(LocalHerdr.resolve("herdr", path: empty.path) { "/from/the/shell" } == nil)
    }

    @Test("--herdr with a path is taken as one, with ~ expanded")
    func explicitPath() {
        #expect(LocalHerdr.resolve("/opt/herdr") { nil } == "/opt/herdr")
        #expect(LocalHerdr.resolve("~/bin/herdr") { nil } == NSHomeDirectory() + "/bin/herdr")
    }
}

#endif
