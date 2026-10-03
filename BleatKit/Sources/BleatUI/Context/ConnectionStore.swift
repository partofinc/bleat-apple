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
    /// Set on a device that cannot connect for itself — the watch. Every host
    /// is then reached by asking the phone, and nothing here dials.
    private let relay: RelayTransport.Channel?

    /// What a dial produced, whichever kind it was.
    private struct Connection: Sendable {
        let client: HerdrClient
        let link: any PeerLink
        /// The address that won. Nil through a relay, where the phone did the
        /// racing and keeps the answer.
        let endpoint: Endpoint?
        let discoveredHerdrPath: String?
    }

    private struct Live {
        /// Which connection this is, counted from launch. See `connectionID`.
        let id: Int
        let hostKey: String
        /// Where the phone was standing when this was raced. A connection made
        /// on Wi-Fi is pinned to whichever address won, so once the phone
        /// leaves that network the cached client can only fail — the peer's
        /// overlay address is never given a turn. A tunnel coming up counts
        /// too: it widens the candidate list, and this one was raced without
        /// it.
        let link: LinkState
        let connected: Connection
    }

    private var current: Live?
    /// How many connections have been installed, which is what numbers them.
    private var installed = 0
    /// A dial in flight, so two screens asking at once do not race every
    /// endpoint twice and leak whichever transport loses the assignment.
    private var connecting: (hostKey: String, task: Task<Connection, any Error>)?
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

    /// - Parameter relay: How to ask the phone, on a device that has to. Nil
    ///   everywhere else, which is what makes this store dial SSH itself.
    public init(peers: PeerStore, reachability: Reachability, relay: RelayTransport.Channel? = nil) {
        self.peers = peers
        self.reachability = reachability
        self.relay = relay
    }

    /// Whether the live connection is to this peer. Observed, so a view that
    /// reads it redraws when the connection goes.
    ///
    /// For work that is only worth doing over a connection somebody else
    /// already wanted — reading the host's load — and must never be the reason
    /// one is dialled.
    public func isConnected(to peer: PairedPeer) -> Bool {
        connectionID(for: peer) != nil
    }

    /// Which connection to this peer is live, or nil when none is. Different
    /// for every connection, so something read over one can be told from the
    /// same host reached again an hour later. Observed, like `isConnected`.
    public func connectionID(for peer: PairedPeer) -> Int? {
        current?.hostKey == peer.hostKey ? current?.id : nil
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
        connected.link.useSession(session ?? peer.session)
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
        try await connected(for: peer, session: nil).link
    }

    /// The connection itself, for a caller that names the session on every
    /// command — the relay answering a watch. Does not touch `useSession`, for
    /// the reason `shell` does not.
    public func link(for peer: PairedPeer) async throws -> any PeerLink {
        try await connected(for: peer, session: nil).link
    }

    /// A shell on the live connection to this peer, with that connection's
    /// number — or nil, rather than a dial, when there is none or it could not
    /// be reused as it stands.
    ///
    /// **For work that must never be the reason for a dial**: reading the
    /// host's load. `shell(for:)` re-dials when the network has changed since
    /// the dial, and a load read that went through it raced the screen's own
    /// list load into `connected(for:)`, where two callers can each release and
    /// each dial before either has set `connecting` — and the second install
    /// orphans the first connection on the host. (Found in review.) Here the
    /// list's load does the re-dial, and the new number is what asks for the
    /// reading. Synchronous, so the shell and its number cannot disagree.
    public func liveShell(for peer: PairedPeer) -> (shell: any ShellRunner, connection: Int)? {
        guard let live = current,
              ConnectionPolicy.canReuse(
                  cachedHostKey: live.hostKey,
                  cachedLink: live.link,
                  for: peer,
                  link: reachability.link
              )
        else { return nil }
        return (live.connected.link, live.id)
    }

    /// The one dial, shared by both. Everything about joining, cancelling and
    /// not leaking a transport lives here rather than being written twice.
    private func connected(
        for peer: PairedPeer,
        session: String?
    ) async throws -> Connection {
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
            let joined = try await pending.task.value
            // Released during the handshake: the caller that started the dial
            // closes it and throws, and a caller that joined must not walk off
            // with the closed connection either. (Found in review.)
            guard !pending.task.isCancelled else { throw CancellationError() }
            return joined
        }

        // **From here to `connecting` being set there is no suspension, and
        // that is what makes this the one dial.** This used to `await
        // release()` first, and a release suspends — it disconnects the old
        // connection and waits for the endpoint refresh. A second caller
        // arriving in that window found neither a live connection nor a dial
        // in flight, released nothing and dialled too; both installed, and the
        // first install was overwritten without being closed — an SSH session
        // left open on the host with nothing referring to it. After a network
        // change, a pull-to-refresh overlapping a screen's own `.task` load was
        // enough; so was the host's load read, until it stopped dialling.
        // (Found in review.) So the old state is taken synchronously and
        // closed *inside* the dial's task, which a caller arriving meanwhile
        // joins. Anything that can throw comes before the detach, so a failure
        // leaves the store as it found it.
        let task: Task<Connection, any Error>
        if let relay {
            // Nothing is dialled: the phone connects when the first command
            // reaches it, and that command is what reports a host that cannot
            // be reached.
            let transport = RelayTransport(hostKey: peer.hostKey, session: session, channel: relay)
            let previous = detach()
            task = Task {
                await self.close(previous)
                return Connection(
                    client: HerdrClient(transport: transport), link: transport,
                    endpoint: nil, discoveredHerdrPath: nil
                )
            }
        } else {
            let deviceKey = try peers.deviceKey()
            let previous = detach()
            task = Task {
                await self.close(previous)
                // Released while the old one was closing: not worth a dial
                // nobody is waiting for.
                try Task.checkCancellation()
                let connected = try await PeerConnection.connect(
                    to: peer, deviceKey: deviceKey, link: link, session: session
                )
                return Connection(
                    client: connected.client, link: connected.transport,
                    endpoint: connected.endpoint, discoveredHerdrPath: connected.discoveredHerdrPath
                )
            }
        }
        connecting = (peer.hostKey, task)
        defer { if connecting?.task == task { connecting = nil } }

        let connected = try await task.value

        // `release()` may have run while the handshake was in flight, and
        // cancelling cannot stop it. Installing now would leave a session open
        // with nobody on screen to close it — the same hazard
        // `SSHTransport.disconnect` guards for its own dial, one level up.
        guard !task.isCancelled else {
            await connected.link.disconnect()
            throw CancellationError()
        }

        installed += 1
        current = Live(id: installed, hostKey: peer.hostKey, link: link, connected: connected)
        endpoint = connected.endpoint

        // Written back so the next connection tries the winner first instead of
        // racing every address again. Failing here would turn a working
        // connection into an error over bookkeeping, so it does not.
        if let endpoint = connected.endpoint {
            peers.recordSuccess(endpoint: endpoint, for: peer)
        }
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
        //
        // And never through a relay: the phone refreshes its own record on its
        // own connection, and the watch's copy of the addresses is not used.
        refresh?.cancel()
        if relay == nil {
            refresh = Task { [peers] in
                await peers.refreshEndpoints(for: peer, over: connected.link)
            }
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
        await close(detach())
    }

    /// What one release is responsible for, taken out of the store.
    private struct Detached {
        let pending: Task<Connection, any Error>?
        let live: Live?
        let refresh: Task<Void, Never>?
    }

    /// The half of a release that must not suspend: takes the dial in flight,
    /// the live connection and the endpoint refresh, and clears them.
    ///
    /// **Everything a release is responsible for is taken before its first
    /// suspension, and that ordering is the whole of its correctness.**
    /// Closing awaits the endpoint refresh, which is bounded only by an
    /// already-running SSH command — the `tailscale` probe carries a five
    /// second watchdog — and a release is started from a screen going away
    /// rather than from something anybody waits on. So a *later* caller can
    /// dial and install a connection inside that window. The old order read
    /// `connecting` and `current` after the await and closed whatever it
    /// found there, which by then could be a brand new connection to a
    /// different host: the user backs out of one Mac, picks another within
    /// a few seconds, and its list screens fail against a transport this
    /// call disconnected from under them.
    ///
    /// Reading them first, and clearing them first, makes that impossible —
    /// a dial that starts afterwards begins from a clean slate and is
    /// invisible here. Cancelling the pending dial before suspending matters
    /// for the same reason: `connected(for:)` re-checks `task.isCancelled`
    /// before installing, and that check is only worth anything if the
    /// cancellation has already happened. And `connected(for:)` relies on
    /// this being synchronous to set its own dial before anyone else looks.
    private func detach() -> Detached {
        let pending = connecting
        connecting = nil
        pending?.task.cancel()

        let live = current
        current = nil
        endpoint = nil

        let refreshing = refresh
        refresh = nil
        refreshing?.cancel()
        return Detached(pending: pending?.task, live: live, refresh: refreshing)
    }

    /// The half that waits: sees each thing `detach` took through to closed.
    private func close(_ detached: Detached) async {
        // Awaited, not abandoned: the cancellation checks inside the probe only
        // help if nothing is mid-command when the transport goes away, and the
        // wait is bounded by one already-running command.
        await detached.refresh?.value

        // Awaited rather than abandoned: cancellation does not stop the
        // handshake, so the only way to be sure nothing is left open is to see
        // what it produced.
        if let connected = try? await detached.pending?.value {
            await connected.link.disconnect()
        }

        guard let live = detached.live else { return }
        await live.connected.link.disconnect()
    }
}
