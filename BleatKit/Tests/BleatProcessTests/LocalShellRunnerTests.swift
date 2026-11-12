#if os(macOS)
import BleatKit
import Foundation
import Testing
@testable import BleatProcess

/// `bleat pair` asks this machine about herdr-core through this, with the
/// phone's own `HerdrCoreCheck.find`; `find` reads a failed version command as
/// "not herdr-core", so a failure must throw rather than answer empty.
@Suite("Commands on this machine, for bleat pair")
struct LocalShellRunnerTests {
    @Test("a command's output comes back")
    func output() async throws {
        #expect(try await LocalShellRunner().run(shell: "echo bleat") == "bleat\n")
    }

    @Test("a failing command throws")
    func failure() async {
        await #expect(throws: ShellError.self) { try await LocalShellRunner().run(shell: "exit 3") }
    }

    @Test("an hc that is not herdr-core is not found, through the phone's own lookup")
    func notHerdrCore() async throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bleat-hc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let bin = home.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let hc = bin.appendingPathComponent("hc")
        try "#!/bin/sh\necho 'usage: hc FILE'\n".write(to: hc, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hc.path)
        // Asked directly at that path: whatever this machine's own PATH holds
        // stays out of it.
        let printed = try await LocalShellRunner().run(shell: HerdrCoreLookup.version(at: hc.path))
        #expect(HerdrCoreLookup.version(inOutput: printed) == nil)
    }
}
#endif
