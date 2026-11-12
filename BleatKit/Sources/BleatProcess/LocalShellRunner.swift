#if !os(iOS)
import BleatKit
import Foundation

/// Commands on this machine, through `/bin/sh -c`, behind the `ShellRunner`
/// seam the phone's SSH transport sits behind.
///
/// So `bleat pair` asks this machine about herdr-core with the very code the
/// phone uses over SSH — `HerdrCoreCheck.find` — instead of a restatement of
/// its steps that could drift: if they disagreed, `bleat pair` would show a
/// code for a host the phone then refuses, or the reverse.
struct LocalShellRunner: ShellRunner {
    /// A profile that waits on something (an agent unlock, a network mount)
    /// would otherwise hang the question. The bound `bleat pair` always had.
    var timeout: TimeInterval = 10

    func run(shell command: String) async throws -> String {
        guard let output = HostInspector().run("/bin/sh", ["-c", command], timeout: timeout) else {
            // `run` gives nil for a non-zero exit, a timeout or a launch
            // failure alike. `find` reads any such failure of the version
            // command as "not herdr-core", which is what each of them means.
            throw ShellError(command: command, exitCode: 1, stderr: "")
        }
        return output
    }
}
#endif
