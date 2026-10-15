// `Foundation.Process` does not exist on iOS, and a whole-package iOS build
// compiles every target whether or not it is vended as a product. The `#if` ban
// in CLAUDE.md applies to BleatKit, whose whole point is being platform-free;
// this target is for machines that run herdr — macOS and Linux —, so guarding it is the honest way to
// say so rather than a workaround.
#if !os(iOS)
import BleatKit
import Foundation

/// Runs `herdr` as a child process on this machine.
///
/// This is the development transport: it exercises the whole stack against a
/// real host without a network, and proves `HerdrTransport` is a genuine seam
/// before `SSHTransport` slots in behind it. Not shipped in the iOS app.
public struct LocalProcessTransport: HerdrTransport {
    private let executable: URL
    private let session: String?

    /// - Parameters:
    ///   - executable: Absolute path to `herdr`. No default: where it lives
    ///     differs per machine, and `HostInspector.locateHerdr()` asks a login
    ///     shell, the same question the phone asks over SSH.
    ///   - session: Named session to talk to. Selection is by environment —
    ///     there is no `--session` flag on the API subcommands.
    public init(executable: URL, session: String? = nil) {
        self.executable = executable
        self.session = session
    }

    /// The child environment, with session selection applied.
    ///
    /// `HERDR_SOCKET_PATH` is stripped: if it survives from our own process it
    /// pins the child to the wrong session and silently ignores `HERDR_SESSION`.
    private var childEnvironment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "HERDR_SOCKET_PATH")
        if let session { env["HERDR_SESSION"] = session }
        return env
    }

    /// `@concurrent`: this blocks a thread until `herdr` exits, and that must
    /// never be the caller's actor.
    @concurrent
    public func run(_ args: [String]) async throws -> Data {
        let process = Process()
        process.executableURL = executable
        process.arguments = args
        process.environment = childEnvironment

        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err

        try process.run()
        // Read before waiting: a full pipe buffer would deadlock the child.
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw HerdrError.fromStderr(command: args, exitCode: process.terminationStatus, stderr: stderr)
        }
        return stdout
    }

    public func openStream(_ args: [String]) async throws -> any HerdrStream {
        try LocalProcessStream(executable: executable, args: args, environment: childEnvironment)
    }
}

#endif
