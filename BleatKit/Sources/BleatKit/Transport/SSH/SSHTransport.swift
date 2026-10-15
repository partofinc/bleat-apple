import Citadel
import Crypto
import Foundation
import NIOCore

/// Reaches Herdr over plain SSH, running `herdr` on exec channels.
///
/// Transport v1: no daemon, no relay, no plugin on the host. One connection
/// carries every channel — list polling and the pane stream run side by side.
public final class SSHTransport: PeerLink, @unchecked Sendable {
    private let host: SSHHost
    private let privateKey: Curve25519.Signing.PrivateKey
    private let validator: PinningHostKeyValidator
    /// Boxed because it can be learned after construction.
    ///
    /// A peer records where `herdr` lives when it is paired, but a record that
    /// predates that carries nil, and the answer only exists once there is a
    /// connection to ask over. Rebuilding the transport to store one string
    /// would mean a second handshake for nothing.
    private let herdrPathBox: LockedBox<String>
    private var herdrPath: String { herdrPathBox.current }
    /// Boxed for the same reason the path is: it is chosen after the connection
    /// exists. The user picks a session from a list the connection fetched, and
    /// `HERDR_SESSION` is a command prefix rather than something negotiated at
    /// the handshake — so switching sessions need not cost a reconnect.
    private let sessionBox: LockedBox<String?>
    private var session: String? { sessionBox.current }

    /// Guarded by `lock`; see `UnsafeTransfer` for why it is boxed.
    private let client = LockedBox<UnsafeTransfer<SSHClient>?>(nil)
    /// Collapses concurrent first calls into a single dial.
    private let dialing = LockedBox<Task<UnsafeTransfer<SSHClient>, any Error>?>(nil)
    /// Set by `disconnect()`, for good. A transport failure only invalidates,
    /// and the next command dials again; a disconnect means the owner has let
    /// go, and a command still holding this transport must not dial a session
    /// nobody will close. (Found in review: backgrounding mid-way through a
    /// pane's opening chain re-dialled, takeover included.)
    private let isClosed = LockedBox(false)

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
        self.herdrPathBox = LockedBox(herdrPath)
        self.sessionBox = LockedBox(session)
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
        if isClosed.current { throw TransportError.channelClosed }
        if let existing = client.current { return existing.value }

        let task = dialing.withLock { inFlight -> Task<UnsafeTransfer<SSHClient>, any Error> in
            if let inFlight { return inFlight }
            let task = Task { [self] in UnsafeTransfer(try await dial()) }
            inFlight = task
            return task
        }

        let connection: UnsafeTransfer<SSHClient>
        do {
            connection = try await task.value
        } catch {
            dialing.withLock { if $0 == task { $0 = nil } }
            throw error
        }
        // Installed only if this dial is still the one in flight. A
        // `disconnect()` that ran during the handshake has taken it away — and
        // a newer dial may have started since — so the client is closed
        // rather than installed over either.
        let installed = dialing.withLock { inFlight -> Bool in
            guard inFlight == task, !isClosed.current else { return false }
            inFlight = nil
            client.withLock { $0 = connection }
            return true
        }
        guard installed else {
            try? await connection.value.close()
            throw TransportError.channelClosed
        }
        return connection.value
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
            // report what actually went wrong. Checked first, because the
            // identity question outranks the credential one.
            if let recorded = validator.recordedFailure { throw recorded }
            // A genuinely refused key, told apart from an unreachable address.
            // Verified against a live sshd (5 Sept 2026): a reachable host that
            // will not accept the key throws exactly this, while an address
            // that is not listening throws `NIOConnectionError`.
            //
            // Worth its own case because the remedy is the opposite: nothing
            // about the network will fix it. This is what a *revoked* device
            // key looks like from the phone — `bleat keys revoke` on the Mac,
            // or a rebuilt host — and reporting it as "no address could be
            // reached" sends the user to check their Wi-Fi forever.
            if case SSHClientError.allAuthenticationOptionsFailed = error {
                // Names the possibilities rather than asserting one. Revocation
                // is the likeliest, but sshd refuses every method for several
                // other reasons — `MaxAuthTries` or `MaxStartups` throttling, a
                // changed `AllowUsers`, a locked account, `StrictModes`
                // rejecting a permissions drift on `~/.ssh`. Several are
                // transient, and this string is what *every* screen shows, so
                // asserting "revoked; pair again" would send a user to re-pair
                // over a host that is briefly busy.
                throw TransportError.authenticationFailed(
                    "it may have been revoked there, or that host's SSH configuration may have changed"
                )
            }
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

    /// Records where `herdr` actually lives, once something has asked the host.
    ///
    /// Only ever narrows the default `"herdr"` to an absolute path, which is
    /// what a non-login shell needs — see `HerdrLookup`.
    public func useHerdrPath(_ path: String) {
        herdrPathBox.withLock { $0 = path }
    }

    /// Selects the named session for every later command.
    ///
    /// Safe on a live connection: session selection is an environment prefix on
    /// each exec channel, not connection state, so nothing already running is
    /// disturbed. It assumes one drill-down at a time, which is what the app
    /// does — the user is inside a single session's workspaces or nowhere.
    public func useSession(_ session: String?) {
        sessionBox.withLock { $0 = session }
    }

    /// Drops the connection, for good: every later command throws
    /// `TransportError.channelClosed` rather than dialling again. A dropped
    /// connection is recovered by the owner making a new transport, which is
    /// what `ConnectionStore` does.
    public func disconnect() async {
        isClosed.withLock { $0 = true }
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
        command(for: args, session: session)
    }

    func command(for args: [String], session: String?) -> String {
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
        try await run(args, inSession: session)
    }

    public func run(_ args: [String], inSession session: String?) async throws -> Data {
        try await execute(command(for: args, session: session)) { exitCode, stderr in
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
    ///
    /// `@concurrent`: every chunk of output is appended here, and the caller
    /// is usually on the main actor — a transcript tail is a few hundred KB.
    @concurrent
    private func execute(
        _ commandLine: String,
        onFailure: @Sendable (Int32, Data) -> any Error
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
    /// `@concurrent` so the decode to `String` stays off the caller's actor too.
    @concurrent
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
