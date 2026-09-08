import BleatKit
import Foundation
import Observation

/// Starting a session on a host, from the phone.
///
/// The first thing Bleat creates on someone's Mac rather than merely reads.
/// Nothing here is destructive — a new session touches no pane and no agent
/// that already exists — but it is a write, and writes in this app are checked
/// rather than assumed. Three reasons, each measured:
///
/// - **The launch cannot report its own failure.** It is detached
///   (`nohup … &`), so the exit status is the shell's and is 0 whichever way it
///   went. See `SessionLaunch`.
/// - **The commonest failure is silent from here.** A session of that name
///   already running exits 1 with `error: herdr server is already running`,
///   into a redirect.
/// - **A name that cannot work should never leave the phone**, so `SessionName`
///   refuses it while the user is still typing.
///
/// So: validate, launch, then read `session list` back until the name appears
/// running — and if it does not, fetch what the launch actually printed and
/// show that. herdr's own sentence is nearly always the whole answer.
@Observable
@MainActor
final class NewSessionModel {
    /// Bound to the field. Not `private(set)`: the text field owns it.
    var name = ""
    private(set) var isStarting = false
    /// Set when the launch did not produce a running session. Cleared on the
    /// next attempt and by editing the name.
    private(set) var failure: String?

    private let connections: ConnectionStore?
    private let peers: PeerStore?

    init(connections: ConnectionStore, peers: PeerStore) {
        self.connections = connections
        self.peers = peers
    }

    #if DEBUG
    /// Parked, for `#Preview`: nothing dials and nothing is launched.
    init(previewing name: String, failure: String? = nil, isStarting: Bool = false) {
        self.connections = nil
        self.peers = nil
        self.name = name
        self.failure = failure
        self.isStarting = isStarting
    }
    #endif

    /// What is wrong with the name as typed, or nil.
    ///
    /// Nil while the field is empty as well as while it is valid: an empty
    /// field is the resting state, not an error to shout about. The button is
    /// disabled either way.
    var nameProblem: String? {
        guard !name.isEmpty, let problem = SessionName.problem(with: name) else { return nil }
        return problem.message
    }

    var canStart: Bool { SessionName(name) != nil && !isStarting }

    /// A session of this name that the host has already told us about.
    ///
    /// Worth surfacing before the tap rather than after: a **running** one is
    /// refused by herdr, and a **stopped** one is not created but *resumed*,
    /// with whatever workspaces it had. Measured — a stopped session restarts
    /// under the same command and keeps its session directory. Neither is a
    /// failure; both are things the user would rather know before pressing a
    /// button labelled with a checkmark.
    func existing(in sessions: [SessionInfo]) -> SessionInfo? {
        guard let name = SessionName(name) else { return nil }
        return sessions.first { $0.name == name.text }
    }

    func clearFailure() { failure = nil }

    /// Launches, then checks. Returns true only if the host is now running a
    /// session of that name.
    ///
    /// - Parameter peer: whose `herdrPath` the launch needs. A record made
    ///   before pairing stored one falls back to a bare `herdr`, which a login
    ///   shell resolves — this command runs through one.
    func start(on peer: PairedPeer) async -> Bool {
        guard let connections, let name = SessionName(name), !isStarting else { return false }
        isStarting = true
        failure = nil
        defer { isStarting = false }

        do {
            // A shell, not a herdr command: `HerdrTransport.run` would apply the
            // screen's own `HERDR_SESSION` prefix and cannot express a detached
            // launch at all. `ConnectionStore.shell` deliberately leaves the
            // session prefix alone, which is what keeps the list behind this
            // overlay reading the session it was already reading.
            let shell = try await connections.shell(for: peer)
            _ = try await shell.run(shell: SessionLaunch.startCommand(
                name: name, herdrPath: peer.herdrPath ?? "herdr"
            ))

            if try await isRunning(name, on: peer) {
                // Recorded only now, and only on a session the host has
                // confirmed running. This is what later permits stopping and
                // deleting it — see `PairedPeer.createdSessions` — so claiming
                // it before the host agreed would hand those actions to a
                // session that may be somebody else's, or may not exist.
                peers?.recordCreatedSession(name.text, for: peer)
                return true
            }
            failure = try await diagnosis(for: name, over: shell)
            return false
        } catch {
            await connections.handle(error)
            failure = ErrorMessage.failure(of: error).message
            return false
        }
    }

    /// Polls `session list` until the name reports running, or the budget runs
    /// out.
    ///
    /// Measured locally at 0.05s — the very first poll — but that was a warm
    /// binary over a unix socket, and this runs over SSH with an exec channel
    /// per attempt. The budget is generous on purpose: telling a user their
    /// session did not start when it started a moment later is the worse of the
    /// two mistakes, and it costs nothing when the usual answer arrives first
    /// time.
    private func isRunning(_ name: SessionName, on peer: PairedPeer) async throws -> Bool {
        // No session prefix, like the list screen: `session list` is a
        // client-side command that reports every session whichever is selected.
        let client = try await connections?.client(for: peer, session: nil)
        guard let client else { return false }
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
    private func diagnosis(for name: SessionName, over shell: any ShellRunner) async throws -> String {
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
