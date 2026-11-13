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
    func physical() async throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bleat-dir-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let odd = base.appendingPathComponent("it's a Dir")
        try FileManager.default.createDirectory(at: odd, withIntermediateDirectories: true)
        let onDisk = try #require(realpath(odd.path, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        })

        let found = try await LocalShellRunner().run(shell: HostDirectory.physical(odd.path))
        #expect(HostDirectory.physical(inOutput: found) == onDisk)
        let missing = try await LocalShellRunner().run(shell: HostDirectory.physical(base.appendingPathComponent("nope").path))
        #expect(missing == "no\n")
        #expect(HostDirectory.physical(inOutput: missing) == nil)
    }

    /// A Mac's disk ignores case, so a typed `~/developer` is a directory;
    /// the answer must be spelled as on disk, or no space folder matches it.
    @Test("a directory typed in another case comes back as it is spelled on disk")
    func spelling() async throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bleat-case-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let real = base.appendingPathComponent("Developer")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let onDisk = try #require(realpath(real.path, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        })

        let typed = base.appendingPathComponent("developer").path
        let printed = try await LocalShellRunner().run(shell: HostDirectory.physical(typed))
        #expect(HostDirectory.physical(inOutput: printed) == onDisk)
        #expect(onDisk.hasPrefix("/private/"), "the temporary directory's symlink is resolved too")
    }
}
#endif
