#if os(macOS)
import BleatKit
import Foundation
import Testing
@testable import BleatProcess

/// The commands starting a terminal asks first, run through a real shell: the
/// quoting is two layers deep, and only a shell says whether it holds.
@Suite("Asking a host about directories, through a real shell")
struct HostDirectoryShellTests {
    @Test("home comes back absolute")
    func home() async throws {
        let printed = try await LocalShellRunner().run(shell: HostDirectory.home)
        #expect(HostDirectory.home(inOutput: printed) == NSHomeDirectory())
    }

    @Test("a directory with a quote and a space in its name is found, and a missing one is not")
    func exists() async throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bleat-dir-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let odd = base.appendingPathComponent("it's a dir")
        try FileManager.default.createDirectory(at: odd, withIntermediateDirectories: true)

        #expect(try await LocalShellRunner().run(shell: HostDirectory.exists(odd.path)) == "yes\n")
        #expect(try await LocalShellRunner().run(shell: HostDirectory.exists(base.appendingPathComponent("nope").path)) == "no\n")
    }
}
#endif
