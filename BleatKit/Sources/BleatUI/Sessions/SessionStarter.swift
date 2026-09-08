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
    /// that name was running *now* — which is true when the launch failed
    /// because it was already up. herdr answers `error: herdr server is already
    /// running` into a log nobody read, the poll saw it running on its first
    /// try, and the phone recorded "we started this" for a session somebody was
    /// working in. That is a Stop button over their agents, which is the one
    /// thing the whole guard exists to prevent, and a stale list is all it
    /// takes: the row said stopped because it was stopped when the list loaded.
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
        // running — claiming it before the host agreed would hand these actions
        // to a session that may not exist.
        //
        // `createdSessions` only when the host had never heard of the name.
        // Restarting an existing session earns a Stop, because this phone is
        // now why it is running, and never a Delete: the layout it would throw
        // away is whoever set it up's. See `PairedPeer.startedSessions`.
        if before == nil { peers?.recordCreatedSession(name.text, for: peer) }
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
        let unknown = "The host did not report a session called \(name.text) after starting it."
        // **Only a line that really is an error.** A launch that worked writes
        // its startup banner and socket paths here, and a host merely slower
        // than the poll's budget would then have that banner shown to the user
        // under the heading "That did not happen" — herdr saying it started as
        // the reason it did not. herdr prefixes its own failures with
        // `error: `; anything else is not a cause.
        guard let failure = log.split(separator: "\n")
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { $0.hasPrefix("error: ") })
        else { return unknown }
        return String(failure.dropFirst("error: ".count))
    }
}
