import BleatKit
import Observation

/// The one live connection, and which peer it belongs to.
///
/// One at a time, deliberately. A phone drills into a single host — sessions,
/// then workspaces, then a pane — and every one of those screens wants the same
/// SSH connection rather than a new handshake each. Browsing a second host
/// closes the first, which is also what should happen: an idle SSH session left
/// open on someone's Mac is untidy at best.
///
/// Keeping that promise takes more than a stored reference, because a dial
/// cannot be called off. `PeerConnector` runs its race in a detached task
/// precisely so a slow address cannot hold up a fast one, which means a
/// handshake started for a screen the user has already left will still finish.
/// Two guards follow from that: concurrent callers join one dial rather than
/// starting a second, and a dial that completes after `release()` closes itself
/// instead of installing.
@Observable
public final class ConnectionStore {
    /// The address the live connection is using, for a screen to show. Nil when
    /// nothing is connected.
    public private(set) var endpoint: Endpoint?

    private let peers: PeerStore
    private let reachability: Reachability

    private struct Live {
        let hostKey: String
        /// Where the phone was standing when this was raced. A connection made
        /// on Wi-Fi is pinned to whichever address won, so once the phone
        /// leaves that network the cached client can only fail — the peer's
        /// overlay address is never given a turn.
        let onLocalLink: Bool
        let connected: PeerConnection.Connected
    }

    private var current: Live?
    /// A dial in flight, so two screens asking at once do not race every
    /// endpoint twice and leak whichever transport loses the assignment.
    private var connecting: (hostKey: String, task: Task<PeerConnection.Connected, any Error>)?

    public init(peers: PeerStore, reachability: Reachability) {
        self.peers = peers
        self.reachability = reachability
    }

    /// A client for this peer, connecting if there is not one already.
    public func client(for peer: PairedPeer) async throws -> HerdrClient {
        let onLocalLink = reachability.isOnLocalLink
        if let live = current,
           ConnectionPolicy.canReuse(
               cachedHostKey: live.hostKey,
               cachedOnLocalLink: live.onLocalLink,
               for: peer,
               onLocalLink: onLocalLink
           ) {
            return live.connected.client
        }

        if let pending = connecting, pending.hostKey == peer.hostKey {
            return try await pending.task.value.client
        }

        await release()

        let deviceKey = try peers.deviceKey()
        let task = Task {
            try await PeerConnection.connect(
                to: peer, deviceKey: deviceKey, onLocalLink: onLocalLink
            )
        }
        connecting = (peer.hostKey, task)
        defer { if connecting?.task == task { connecting = nil } }

        let connected = try await task.value

        // `release()` may have run while the handshake was in flight, and
        // cancelling cannot stop it. Installing now would leave a session open
        // with nobody on screen to close it — the same hazard
        // `SSHTransport.disconnect` guards for its own dial, one level up.
        guard !task.isCancelled else {
            await connected.transport.disconnect()
            throw CancellationError()
        }

        current = Live(hostKey: peer.hostKey, onLocalLink: onLocalLink, connected: connected)
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

    /// Drops the connection when an error means the connection itself is
    /// finished, so the next attempt races the peer's addresses again.
    ///
    /// `HerdrError` deliberately does not qualify: the host was reached and
    /// said no, and throwing away a working connection over one failed command
    /// would make every retry pay for a fresh handshake.
    ///
    /// Without this a cached client outlives the network it was made on. Move
    /// from Wi-Fi to cellular and it is still pinned to the `.local` name that
    /// won the race; every command fails, and "Try again" asks the same dead
    /// connection forever.
    public func handle(_ error: any Error) async {
        guard ConnectionPolicy.isFatalToConnection(error) else { return }
        await release()
    }

    /// Closes whatever is open, including a dial that has not finished.
    /// Idempotent.
    public func release() async {
        let pending = connecting
        connecting = nil
        pending?.task.cancel()
        // Awaited rather than abandoned: cancellation does not stop the
        // handshake, so the only way to be sure nothing is left open is to see
        // what it produced.
        if let connected = try? await pending?.task.value {
            await connected.transport.disconnect()
        }

        guard let live = current else { return }
        current = nil
        endpoint = nil
        await live.connected.transport.disconnect()
    }
}
