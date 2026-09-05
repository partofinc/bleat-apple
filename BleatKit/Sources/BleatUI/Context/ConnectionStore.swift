import BleatKit
import Observation

/// The one live connection, and which peer it belongs to.
///
/// One at a time, deliberately. A phone drills into a single host — sessions,
/// then workspaces, then a pane — and every one of those screens wants the same
/// SSH connection rather than a new handshake each. Browsing a second host
/// closes the first, which is also what should happen: an idle SSH session left
/// open on someone's Mac is untidy at best.
@Observable
public final class ConnectionStore {
    /// The address the live connection is using, for a screen to show. Nil when
    /// nothing is connected.
    public private(set) var endpoint: Endpoint?

    private let peers: PeerStore
    private let reachability: Reachability
    private var current: (hostKey: String, connected: PeerConnection.Connected)?

    public init(peers: PeerStore, reachability: Reachability) {
        self.peers = peers
        self.reachability = reachability
    }

    /// A client for this peer, connecting if there is not one already.
    ///
    /// The client is cheap to hold and reusable after a dropped socket —
    /// `SSHTransport` re-dials on the next command — so a backgrounded app that
    /// comes back does not need to do anything special here.
    public func client(for peer: PairedPeer) async throws -> HerdrClient {
        if let current, current.hostKey == peer.hostKey {
            return current.connected.client
        }
        await release()

        let connected = try await PeerConnection.connect(
            to: peer,
            deviceKey: try peers.deviceKey(),
            onLocalLink: reachability.isOnLocalLink
        )
        current = (peer.hostKey, connected)
        endpoint = connected.endpoint

        // Written back so the next connection tries the winner first instead of
        // racing every address again. Failing here would turn a working
        // connection into an error over bookkeeping, so it does not.
        peers.recordSuccess(endpoint: connected.endpoint, for: peer)
        if let path = connected.discoveredHerdrPath {
            peers.recordHerdrPath(path, for: peer)
        }
        return connected.client
    }

    /// Closes whatever is open. Idempotent.
    public func release() async {
        guard let existing = current else { return }
        current = nil
        endpoint = nil
        await existing.connected.transport.disconnect()
    }
}
