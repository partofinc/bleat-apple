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
        /// overlay address is never given a turn. A tunnel coming up counts
        /// too: it widens the candidate list, and this one was raced without
        /// it.
        let link: LinkState
        let connected: PeerConnection.Connected
    }

    private var current: Live?
    /// A dial in flight, so two screens asking at once do not race every
    /// endpoint twice and leak whichever transport loses the assignment.
    private var connecting: (hostKey: String, task: Task<PeerConnection.Connected, any Error>)?
    /// The background endpoint refresh, held so it can be cancelled *and*
    /// waited for.
    ///
    /// **Cancelling is not enough, and this is the part that bites.**
    /// `SSHTransport` re-dials lazily when its client is nil, and
    /// `SSHClient.connect` does not observe cancellation — so a probe that runs
    /// after `release()` has disconnected opens a brand new SSH session that
    /// this store no longer references and will never close. An orphaned
    /// session on the user's Mac is the one thing this type promises not to
    /// leave behind. `EndpointDiscovery.probe` checks `Task.isCancelled`
    /// between every command for that reason, and `release()` awaits the task
    /// rather than walking away from it, exactly as it already does for a dial
    /// in flight.
    private var refresh: Task<Void, Never>?

    public init(peers: PeerStore, reachability: Reachability) {
        self.peers = peers
        self.reachability = reachability
    }

    /// A client for this peer, connecting if there is not one already.
    ///
    /// - Parameter session: The Herdr session to select. Applied to the live
    ///   connection rather than being part of its identity: session selection
    ///   is an environment prefix on each command, so drilling from the session
    ///   list into a session's workspaces costs no second handshake.
    public func client(for peer: PairedPeer, session: String? = nil) async throws -> HerdrClient {
        let connected = try await connected(for: peer, session: session)
        // Applied on every path, including a fresh dial. The three used to
        // differ — a reused or joined connection took `session ?? peer.session`
        // while a new one took only `session` — and a screen could not tell
        // which it had got. (`peer.session` is unset today, so this changes
        // nothing yet; it stops the paths disagreeing when it is not.)
        connected.transport.useSession(session ?? peer.session)
        return connected.client
    }

    /// A client for a command that does not care which session is selected.
    ///
    /// **Deliberately does not call `useSession`**, for the reason `shell` does
    /// not: the prefix is shared mutable state on one transport, read at
    /// command dispatch rather than when the client was handed out. A screen
    /// that is inside a session now asks two questions over one connection —
    /// `workspace list`, which needs the prefix, and `session list`, which does
    /// not — and passing `session: nil` for the second would clear the prefix
    /// out from under the first if the two overlapped. `.task` and
    /// `.refreshable` overlap routinely.
    ///
    /// `session list`, `session stop` and `session delete` are all client-side
    /// commands that name their session explicitly and report every session
    /// whichever one is selected, so leaving the prefix alone costs nothing.
    public func sessionAgnosticClient(for peer: PairedPeer) async throws -> HerdrClient {
        try await connected(for: peer, session: nil).client
    }

    /// A shell on the peer, over the same connection every screen uses.
    ///
    /// Pairing and unpairing are plain shell, not herdr — installing and
    /// removing a key in `authorized_keys` has nothing to do with sessions, so
    /// this deliberately does **not** touch `useSession`. The prefix is shared
    /// mutable state on a shared transport, and setting it here would change
    /// which session a list screen behind the sheet is reading.
    public func shell(for peer: PairedPeer) async throws -> any ShellRunner {
        try await connected(for: peer, session: nil).transport
    }

    /// The one dial, shared by both. Everything about joining, cancelling and
    /// not leaking a transport lives here rather than being written twice.
    private func connected(
        for peer: PairedPeer,
        session: String?
    ) async throws -> PeerConnection.Connected {
        let link = reachability.link
        if let live = current,
           ConnectionPolicy.canReuse(
               cachedHostKey: live.hostKey,
               cachedLink: live.link,
               for: peer,
               link: link
           ) {
            return live.connected
        }

        if let pending = connecting, pending.hostKey == peer.hostKey {
            return try await pending.task.value
        }

        await release()

        let deviceKey = try peers.deviceKey()
        let task = Task {
            try await PeerConnection.connect(
                to: peer, deviceKey: deviceKey, link: link, session: session
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

        current = Live(hostKey: peer.hostKey, link: link, connected: connected)
        endpoint = connected.endpoint

        // Written back so the next connection tries the winner first instead of
        // racing every address again. Failing here would turn a working
        // connection into an error over bookkeeping, so it does not.
        peers.recordSuccess(endpoint: connected.endpoint, for: peer)
        if let path = connected.discoveredHerdrPath {
            peers.recordHerdrPath(path, for: peer)
        }

        // Ask the host what its addresses are now, so a Mac that moved network
        // or gained a tunnel does not cost a re-pair. Started here rather than
        // awaited, and after the connection is installed, for two reasons: the
        // caller is a screen waiting to draw a list, and this is bookkeeping
        // nobody asked for. Three exec channels behind a list load is invisible;
        // three in front of it is a stall on every drill-down.
        //
        // Only on a fresh dial. A reused connection returns above without
        // reaching here, which is what keeps this to once per screen rather
        // than once per request.
        refresh?.cancel()
        refresh = Task { [peers] in
            await peers.refreshEndpoints(for: peer, over: connected.transport)
        }
        return connected
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
        // **Everything this call is responsible for is taken before the first
        // suspension, and that ordering is the whole of its correctness.**
        // This awaits the endpoint refresh, which is bounded only by an
        // already-running SSH command — the `tailscale` probe carries a five
        // second watchdog — and a release is started from a screen going away
        // rather than from something anybody waits on. So a *later* caller can
        // dial and install a connection inside that window. The old order read
        // `connecting` and `current` after the await and closed whatever it
        // found there, which by then could be a brand new connection to a
        // different host: the user backs out of one Mac, picks another within
        // a few seconds, and its list screens fail against a transport this
        // call disconnected from under them.
        //
        // Reading them first, and clearing them first, makes that impossible —
        // a dial that starts afterwards begins from a clean slate and is
        // invisible here. Cancelling `pending` before suspending matters for
        // the same reason: `connected(for:)` re-checks `task.isCancelled`
        // before installing, and that check is only worth anything if the
        // cancellation has already happened.
        let pending = connecting
        connecting = nil
        pending?.task.cancel()

        let live = current
        current = nil
        endpoint = nil

        let refreshing = refresh
        refresh = nil
        refreshing?.cancel()
        // Awaited, not abandoned: the cancellation checks inside the probe only
        // help if nothing is mid-command when the transport goes away, and the
        // wait is bounded by one already-running command.
        await refreshing?.value

        // Awaited rather than abandoned: cancellation does not stop the
        // handshake, so the only way to be sure nothing is left open is to see
        // what it produced.
        if let connected = try? await pending?.task.value {
            await connected.transport.disconnect()
        }

        guard let live else { return }
        await live.connected.transport.disconnect()
    }
}
