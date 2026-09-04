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
    ///   - executable: Absolute path to `herdr`. A login shell may not have it
    ///     on `PATH`, so an explicit path is the default posture.
    ///   - session: Named session to talk to. Selection is by environment —
    ///     there is no `--session` flag on the API subcommands.
    public init(executable: URL = URL(fileURLWithPath: "/opt/homebrew/bin/herdr"), session: String? = nil) {
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
            throw Self.error(command: args, exitCode: process.terminationStatus, stderr: stderr)
        }
        return stdout
    }

    public func openStream(_ args: [String]) async throws -> any HerdrStream {
        try LocalProcessStream(executable: executable, args: args, environment: childEnvironment)
    }

    /// Builds a `HerdrError`, preferring the structured body.
    ///
    /// On failure herdr writes `{"id":…,"error":{"code","message"}}` to
    /// **stderr**, not stdout, and exits non-zero.
    static func error(command: [String], exitCode: Int32, stderr: Data) -> HerdrError {
        let text = String(decoding: stderr, as: UTF8.self)
        let body = stderr
            .split(separator: 0x0A)
            .lazy
            .compactMap { try? JSONDecoder().decode(HerdrErrorEnvelope.self, from: Data($0)) }
            .first?
            .error
        return HerdrError(
            command: command,
            exitCode: exitCode,
            stderr: text,
            code: body?.code,
            message: body?.message
        )
    }
}
