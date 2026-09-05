import Citadel
import Crypto
import Foundation
import NIOCore

/// Reaches Herdr over plain SSH, running `herdr` on exec channels.
///
/// Transport v1: no daemon, no relay, no plugin on the host. One connection
/// carries every channel — list polling and the pane stream run side by side.
public final class SSHTransport: HerdrTransport, @unchecked Sendable {
    private let host: SSHHost
    private let privateKey: Curve25519.Signing.PrivateKey
    private let validator: PinningHostKeyValidator
    private let herdrPath: String
    private let session: String?

    /// Guarded by `lock`; see `UnsafeTransfer` for why it is boxed.
    private let client = LockedBox<UnsafeTransfer<SSHClient>?>(nil)
    /// Collapses concurrent first calls into a single dial.
    private let dialing = LockedBox<Task<UnsafeTransfer<SSHClient>, any Error>?>(nil)

    /// - Parameters:
    ///   - herdrPath: Absolute path is the safe default — a non-login shell
    ///     often lacks `herdr` on `PATH`.
    ///   - session: Named session, applied as a command prefix (see `command`).
    ///   - hostKeys: How to decide the machine that answered is the right one.
    ///     A paired peer supplies `.expect(peer.hostKey)`, which is the pin;
    ///     the console tool falls back to the trust-on-first-use file.
    public init(
        host: SSHHost,
        privateKey: Curve25519.Signing.PrivateKey,
        hostKeys: HostKeyPolicy = .standard,
        herdrPath: String = "herdr",
        session: String? = nil
    ) {
        self.host = host
        self.privateKey = privateKey
        self.validator = PinningHostKeyValidator(host: host.pinKey, policy: hostKeys)
        self.herdrPath = herdrPath
        self.session = session
    }

    /// Loads an OpenSSH ed25519 private key from disk.
    public static func privateKey(atPath path: String) throws -> Curve25519.Signing.PrivateKey {
        let text = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
        return try Curve25519.Signing.PrivateKey(sshEd25519: text)
    }

    // MARK: - Connection

    /// Connects on demand and reuses the connection.
    ///
    /// `HerdrClient` is meant to survive a dropped socket, so this is
    /// deliberately re-entrant: a failed connection is discarded and the next
    /// call dials again.
    private func connected() async throws -> SSHClient {
        if let existing = client.current { return existing.value }

        let task = dialing.withLock { inFlight -> Task<UnsafeTransfer<SSHClient>, any Error> in
            if let inFlight { return inFlight }
            let task = Task { [self] in UnsafeTransfer(try await dial()) }
            inFlight = task
            return task
        }

        do {
            let connection = try await task.value
            client.withLock { $0 = connection }
            dialing.withLock { $0 = nil }
            return connection.value
        } catch {
            dialing.withLock { $0 = nil }
            throw error
        }
    }

    private func dial() async throws -> SSHClient {
        // Stale state would otherwise report an old mismatch forever: after one
        // host-key failure, every later dial — however it failed — would claim
        // the key changed and send the user to edit known_hosts.
        validator.clearRecordedFailure()
        do {
            return try await SSHClient.connect(
                host: host.hostname,
                port: host.port,
                authenticationMethod: .ed25519(username: host.username, privateKey: privateKey),
                hostKeyValidator: .custom(validator),
                reconnect: .never
            )
        } catch {
            // A host-key mismatch surfaces from NIO as a generic auth failure;
            // report what actually went wrong.
            if let recorded = validator.recordedFailure { throw recorded }
            throw TransportError.connectionFailed(String(describing: error))
        }
    }

    /// Dials, without running anything.
    ///
    /// What "this endpoint works" means: TCP, the host key, key exchange and
    /// authentication. `PeerConnector` races this rather than a shell command,
    /// because a shell command's *output* is not a reliable signal — `.zshenv`
    /// is sourced for every non-interactive zsh, and anything it prints would
    /// make a healthy endpoint look broken.
    public func connect() async throws {
        _ = try await connected()
    }

    /// Drops the connection. The next call reconnects.
    public func disconnect() async {
        // Cancel first: a dial still in flight would otherwise install its
        // client after this returns, leaving the transport connected when the
        // caller asked for the opposite (iOS backgrounding does exactly this).
        let pending = dialing.withLock { current -> Task<UnsafeTransfer<SSHClient>, any Error>? in
            defer { current = nil }
            return current
        }
        pending?.cancel()
        if let connection = try? await pending?.value {
            try? await connection.value.close()
        }
        await invalidate()
    }

    /// Closes and forgets the current connection.
    private func invalidate() async {
        let existing = client.withLock { current -> UnsafeTransfer<SSHClient>? in
            defer { current = nil }
            return current
        }
        try? await existing?.value.close()
    }

    // MARK: - Commands

    /// Builds the remote command line.
    ///
    /// Session selection is by environment, but SSH channel env requests need
    /// `PermitUserEnvironment` on the server, which is off by default. sshd
    /// runs an exec command through the login shell, so a `VAR=value` prefix
    /// works without any server configuration.
    ///
    /// `HERDR_SOCKET_PATH` is cleared: if it leaks in from the remote
    /// environment it pins the command to the wrong session and silently
    /// overrides `HERDR_SESSION`.
    func command(for args: [String]) -> String {
        var parts = ["env", "-u", "HERDR_SOCKET_PATH"]
        if let session { parts.append("HERDR_SESSION=\(Self.quote(session))") }
        parts.append(Self.quote(herdrPath))
        parts.append(contentsOf: args.map(Self.quote))
        return parts.joined(separator: " ")
    }

    /// Single-quotes for POSIX shells; the only escape inside is `'\''`.
    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    public func run(_ args: [String]) async throws -> Data {
        try await execute(command(for: args)) { exitCode, stderr in
            // herdr writes its error envelope to stderr and exits non-zero.
            HerdrError.fromStderr(command: args, exitCode: exitCode, stderr: stderr)
        }
    }

    /// Runs one command on its own exec channel and returns stdout.
    ///
    /// - Parameter onFailure: builds the error for a non-zero exit. The two
    ///   callers describe failure differently — a `herdr` command that was
    ///   reached and said no, against a shell command that did not do what it
    ///   was told — and nothing else about the channel differs.
    private func execute(
        _ commandLine: String,
        onFailure: (Int32, Data) -> any Error
    ) async throws -> Data {
        let connection = try await connected()
        var stdout = Data(), stderr = Data()

        do {
            for try await chunk in try await connection.executeCommandStream(commandLine) {
                switch chunk {
                case .stdout(let buffer): stdout.append(contentsOf: buffer.readableBytesView)
                case .stderr(let buffer): stderr.append(contentsOf: buffer.readableBytesView)
                }
            }
        } catch let failure as SSHClient.CommandFailed {
            throw onFailure(Int32(clamping: failure.exitCode), stderr)
        } catch is CancellationError {
            // The caller went away; the connection is still fine.
            throw CancellationError()
        } catch {
            // Discarding the reference is not enough: SSHClient has no deinit
            // that closes the channel, so an unclosed session would linger on
            // the host and the next call would dial a second one.
            await invalidate()
            throw TransportError.connectionFailed(String(describing: error))
        }
        return stdout
    }

    public func openStream(_ args: [String]) async throws -> any HerdrStream {
        let connection = try await connected()
        return await SSHStream(client: connection, command: command(for: args), args: args)
    }
}

/// Pairing runs shell commands, not `herdr` commands: installing a key in
/// `authorized_keys` and finding where `herdr` lives are both plain shell. The
/// conformance sits on the transport so both kinds of work share one
/// connection, one dial and one host key check.
extension SSHTransport: ShellRunner {
    public func run(shell command: String) async throws -> String {
        let stdout = try await execute(command) { exitCode, stderr in
            ShellError(
                command: command,
                exitCode: exitCode,
                stderr: String(decoding: stderr, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return String(decoding: stdout, as: UTF8.self)
    }
}
