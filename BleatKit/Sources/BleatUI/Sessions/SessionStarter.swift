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

    /// Looks first, launches, checks, then records.
    ///
    /// **The look comes first, and it is what the claims are derived from.**
    /// An earlier version launched and then asked only whether a session of
    /// that name was running *now* — which is true when the launch did nothing
    /// because it was already up. The poll saw it running on its first try and
    /// the phone recorded "we started this" for a session somebody was working
    /// in. A stale list is all it takes: the row said stopped because it was
    /// stopped when the list loaded. What that costs is now a **Delete** over
    /// their layout — `createdSessions` is the claim still gating an action —
    /// and, on the other claim, a stop confirmation that does not warn them
    /// the session is not this phone's. It used to be a Stop button over their
    /// agents, which is what this rule was written for.
    ///
    /// **`session attach` makes this rule matter more than it used to, not
    /// less.** The old `herdr server` at least failed loudly at an already-
    /// running session (`error: herdr server is already running`, into a log
    /// nobody read). `attach` is idempotent — measured: same pid, no error, no
    /// second server — so the launch against somebody's live session is
    /// silently indistinguishable from starting a fresh one. This look is now
    /// the only thing standing between that and a false claim.
    ///
    /// The same look settles the other claim. The caller used to say whether
    /// this was a creation, and the field that names a session always said yes
    /// — including when the name matched a stopped session it had itself
    /// offered to *resume*. Typing the name of a session somebody set up at the
    /// Mac then earned a Delete over their layout. The host knows which it is;
    /// the caller only thinks it does.
    ///
    /// - Throws: whatever the transport or herdr threw. A launch that ran and
    ///   produced no session comes back as `.failed` instead, because there is
    ///   nothing to throw — see below.
    static func start(
        _ name: SessionName,
        on peer: PairedPeer,
        connections: ConnectionStore,
        peers: PeerStore?
    ) async throws -> Outcome {
        let before = try await connections.sessionAgnosticClient(for: peer)
            .sessions()
            .first { $0.name == name.text }

        // Already up, so nothing here started it and nothing may claim it.
        // herdr would refuse the launch anyway; the point is to refuse the
        // *claim*.
        guard before?.running != true else {
            return .failed("\(name.text) is already running on this host.")
        }

        // A shell, not a herdr command: `HerdrTransport.run` would apply the
        // screen's own `HERDR_SESSION` prefix, which is exactly the variable
        // this command unsets so the name it was given is the name that starts.
        // `ConnectionStore.shell` deliberately leaves that prefix alone, which
        // is what keeps the list on screen reading the session it was already
        // reading.
        let shell = try await connections.shell(for: peer)
        // **Kept, and it is the whole of the failure report.** The launch emits
        // the client's output only when the session did not come up, so this
        // string is empty on every start that worked and is the only account
        // there will be of one that did not. `SessionLaunch.diagnosis` reads
        // it, and reads herdr's `herdr: ` refusals as well as its `error: `
        // ones for that reason.
        let launchOutput = try await shell.run(shell: SessionLaunch.startCommand(
            name: name, herdrPath: peer.herdrPath ?? "herdr"
        ))

        guard try await isRunning(name, on: peer, connections: connections) else {
            return .failed(
                SessionLaunch.diagnosis(inLaunchOutput: launchOutput)
                    ?? "The host did not report a session called \(name.text) after starting it."
            )
        }
        // Recorded only now, and only on a session the host has confirmed
        // running — claiming it before the host agreed would hand these actions
        // to a session that may not exist.
        //
        // `createdSessions` only when the host had never heard of the name.
        // Restarting an existing session never earns a Delete: the layout it
        // would throw away is whoever set it up's. Stop needs no claim — it is
        // offered for anything running — so what `startedSessions` buys is the
        // shorter confirmation on a session this phone really did bring up.
        // See `PairedPeer.startedSessions`.
        if before == nil { peers?.recordCreatedSession(name.text, for: peer) }
        peers?.recordStartedSession(name.text, for: peer)
        return .started
    }

    /// Polls `session list` until the name reports running, or the budget runs
    /// out.
    ///
    /// **The launch cannot confirm its own success, and this read is not
    /// redundant with the one inside it.** `SessionLaunch.startCommand` polls
    /// the session's own socket so it knows when to kill the client — but that
    /// poll is *inside* the thing being checked, and it runs on the host with
    /// nothing above it to disagree. A launch that fell through its budget, or
    /// a `script` the host does not have, both leave a command that exited 0.
    /// So the answer still comes from reading `session list` back, exactly as
    /// it does for a revocation.
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
        // Session-agnostic, and it matters here more than anywhere: this
        // client is held across up to 3.5s of polling, and asking with
        // `session: nil` would clear the prefix a workspaces load on the same
        // screen depends on for that whole window.
        let client = try await connections.sessionAgnosticClient(for: peer)
        for attempt in 0..<8 {
            if attempt > 0 { try await Task.sleep(for: .milliseconds(500)) }
            try Task.checkCancellation()
            if try await client.sessions().contains(where: { $0.name == name.text && $0.running }) {
                return true
            }
        }
        return false
    }
}
