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
            switch try await SessionStarter.start(
                name, on: peer, connections: connections, peers: peers, claimAsCreated: true
            ) {
            case .started: return true
            case .failed(let why): failure = why; return false
            }
        } catch {
            await connections.handle(error)
            failure = ErrorMessage.failure(of: error).message
            return false
        }
    }
}
