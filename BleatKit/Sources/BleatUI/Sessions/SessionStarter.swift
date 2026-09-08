import BleatKit
import Foundation

/// Launching a session and confirming it came up.
///
/// Shared by the field that names a new one (`NewSessionModel`) and the button
/// that restarts a stopped one (`SessionControlModel`), because they are the
/// same operation: herdr has no `session create`, and starting a session that
/// exists but is stopped runs the identical command — it simply resumes, with
/// the workspaces it had. Two copies of this would drift, and the parts that
/// would drift are the two that took measuring.
@MainActor
enum SessionStarter {
    enum Outcome: Equatable {
        case started
        /// It did not come up, and this is the host's own account of why.
        case failed(String)
    }

    /// Launches, then checks, then records.
    ///
    /// - Parameter claimAsCreated: whether this is a session the phone made
    ///   from nothing, as opposed to one it restarted. Only the first earns a
    ///   Delete later — deleting removes the session directory, and for a
    ///   session somebody else set up that is their layout, not ours. Both earn
    ///   a Stop, because the phone may undo what it did.
    /// - Throws: whatever the transport or herdr threw. A launch that ran and
    ///   produced no session comes back as `.failed` instead, because there is
    ///   nothing to throw — see below.
    static func start(
        _ name: SessionName,
        on peer: PairedPeer,
        connections: ConnectionStore,
        peers: PeerStore?,
        claimAsCreated: Bool
    ) async throws -> Outcome {
        // A shell, not a herdr command: `HerdrTransport.run` would apply the
        // screen's own `HERDR_SESSION` prefix and cannot express a detached
        // launch at all. `ConnectionStore.shell` deliberately leaves the
        // session prefix alone, which is what keeps the list on screen reading
        // the session it was already reading.
        let shell = try await connections.shell(for: peer)
        _ = try await shell.run(shell: SessionLaunch.startCommand(
            name: name, herdrPath: peer.herdrPath ?? "herdr"
        ))

        guard try await isRunning(name, on: peer, connections: connections) else {
            return .failed(try await diagnosis(for: name, over: shell))
        }
        // Recorded only now, and only on a session the host has confirmed
        // running. This is what later permits stopping and deleting it — see
        // `PairedPeer.createdSessions` — so claiming it before the host agreed
        // would hand those actions to a session that may be somebody else's, or
        // may not exist.
        if claimAsCreated { peers?.recordCreatedSession(name.text, for: peer) }
        peers?.recordStartedSession(name.text, for: peer)
        return .started
    }

    /// Polls `session list` until the name reports running, or the budget runs
    /// out.
    ///
    /// **The launch cannot report its own failure** — it is detached, so the
    /// exit status is the shell's and is 0 whichever way it went. Checking is
    /// the only way to know, exactly as it is for a revocation.
    ///
    /// Measured locally at 0.05s, on the very first poll, but that was a warm
    /// binary over a unix socket; this runs over SSH with an exec channel per
    /// attempt. The budget is generous on purpose: telling a user their session
    /// did not start when it started a moment later is the worse of the two
    /// mistakes, and it costs nothing when the usual answer arrives first time.
    private static func isRunning(
        _ name: SessionName,
        on peer: PairedPeer,
        connections: ConnectionStore
    ) async throws -> Bool {
        // No session prefix, like the list screen: `session list` is a
        // client-side command that reports every session whichever is selected.
        let client = try await connections.client(for: peer, session: nil)
        for attempt in 0..<8 {
            if attempt > 0 { try await Task.sleep(for: .milliseconds(500)) }
            try Task.checkCancellation()
            if try await client.sessions().contains(where: { $0.name == name.text && $0.running }) {
                return true
            }
        }
        return false
    }

    /// What the launch printed, turned into something worth reading.
    ///
    /// The log is the only channel herdr's complaint has — everything else
    /// about a detached launch succeeds. Fetching it is best effort: a failure
    /// to read it must not replace the more useful "it did not start" with an
    /// error about a `cat`.
    private static func diagnosis(
        for name: SessionName,
        over shell: any ShellRunner
    ) async throws -> String {
        let log = (try? await shell.run(shell: SessionLaunch.logCommand(name: name)))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !log.isEmpty else {
            return "The host did not report a session called \(name.text) after starting it."
        }
        // herdr's own wording, first line first — the rest is the socket paths
        // it prints on success, which say nothing about a failure.
        let first = log.split(separator: "\n").first.map(String.init) ?? log
        return first.replacingOccurrences(of: "error: ", with: "")
    }
}
