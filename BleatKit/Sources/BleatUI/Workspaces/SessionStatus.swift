import BleatKit
import Observation

/// One session's row from `session list`, for the screen that is inside it.
///
/// **The route cannot carry it.** `NavigationRouter.Route.workspaces` holds a
/// name, deliberately — a pushed value has to survive the list beneath it being
/// refreshed, and a route whose identity included `running` would become a
/// different route the moment the session stopped, which is exactly when this
/// screen needs to stay put.
///
/// So it is fetched. One extra `session list` behind a screen that is already
/// opening a connection and listing workspaces is invisible, and it is the only
/// way the bar can know whether to offer Start or Stop.
///
/// `nil` is not "stopped": it is "not asked yet, or the host could not be
/// reached", and the bar shows nothing at all rather than guessing. Offering
/// Start for a session that is running — or Stop for one that is not — is an
/// action herdr refuses, and finding that out by tapping is a poor way to be
/// told.
@Observable
@MainActor
final class SessionStatus {
    private(set) var info: SessionInfo?

    private let connections: ConnectionStore?
    private let name: String?
    /// Only to reconcile the started-session claim against what comes back —
    /// see `PeerStore.reconcileStartedSessions`. This screen's bar offers Stop,
    /// so the freshest `session list` it reads is worth spending on that.
    private let peers: PeerStore?

    init(connections: ConnectionStore, name: String?, peers: PeerStore) {
        self.connections = connections
        self.name = name
        self.peers = peers
    }

    #if DEBUG
    /// Handed in, for `#Preview`: nothing is fetched.
    init(previewing info: SessionInfo?) {
        self.connections = nil
        self.name = info?.name
        self.peers = nil
        self.info = info
    }
    #endif

    /// Refreshes quietly. A failure leaves the last answer standing rather than
    /// blanking the bar: the workspaces list beside it reports connection
    /// trouble already, and two messages about one dropped packet is one too
    /// many.
    func load(for peer: PairedPeer) async {
        guard let connections, let name else { return }
        // Session-agnostic: `session list` reports every session whichever one
        // is selected, and asking with `session: nil` would clear the prefix
        // that the workspaces load beside this one depends on.
        guard let client = try? await connections.sessionAgnosticClient(for: peer),
              let sessions = try? await client.sessions()
        else { return }
        // The whole list came back, not just this session's row, so the claim
        // on every one of them can be checked against it while it is in hand.
        peers?.reconcileStartedSessions(with: sessions, forHostKey: peer.hostKey)
        info = sessions.first { $0.name == name }
    }
}
