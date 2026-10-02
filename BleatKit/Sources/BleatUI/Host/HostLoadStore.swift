import BleatKit
import Observation

/// How busy the connected host is, for the bar carried down its screens.
///
/// One reading, for one host, exactly as `ConnectionStore` holds one
/// connection: the host, its sessions and a workspace are three screens deep
/// in one machine, and each shows what the last one read rather than starting
/// from nothing.
///
/// **It never dials.** A reading is taken only over a connection that is
/// already up, and shown only while that connection still is. Two reasons, and
/// the second is the one that bites: this is a glance nobody should pay a
/// handshake for — and a screen drawn in a preview or a test has no
/// connection, so a read that was willing to open one would dial a real host
/// from the canvas. The screens ask for a reading *after* their own list has
/// loaded, which is what brought the connection up.
///
/// **Best effort, and silent when it fails.** The list above the bar is loaded
/// over the same connection and already says when the host cannot be reached.
/// For the same reason this does not call `ConnectionStore.handle`: two loads
/// each releasing the connection over one failure would have the slower tear
/// down what the faster one's retry had just dialled.
@Observable
public final class HostLoadStore {
    /// **Tied to the connection it was read over, not just to the host.** The
    /// app releases its connection in the background; an hour later the same
    /// host is dialled again, and a reading matched on the host alone would
    /// come back on screen as if it were live.
    private var reading: (hostKey: String, connection: Int?, load: HostLoad)?
    private var readAt: ContinuousClock.Instant?
    /// The host a read is in flight for, so three screens pushed in a second
    /// do not each start one.
    private var refreshing: String?
    /// Bumped by every read, so a slow one cannot land over a newer one.
    private var generation = 0
    #if DEBUG
    private var isPreview = false
    #endif

    private let connections: ConnectionStore
    private let peers: PeerStore

    /// How long a reading stands before a screen appearing is worth another.
    /// A pull-to-refresh always reads.
    static let fresh = Duration.seconds(10)

    init(connections: ConnectionStore, peers: PeerStore) {
        self.connections = connections
        self.peers = peers
    }

    /// The last reading for this host, while the connection it was read over
    /// is still up. Nil the moment it is not: a load from before a disconnect
    /// is a number about a machine nobody is talking to.
    func load(for peer: PairedPeer) -> HostLoad? {
        // An empty one is kept only so it is not waited for twice — see
        // `isAwaitingFirstReading`.
        guard let reading, reading.hostKey == peer.hostKey, !reading.load.isEmpty else {
            return nil
        }
        #if DEBUG
        if isPreview { return reading.load }
        #endif
        return reading.connection == connections.connectionID(for: peer) ? reading.load : nil
    }

    /// Whether the first read over this connection is in flight — what a list
    /// that keeps a row for the load draws a placeholder on.
    ///
    /// **Only the first.** A host whose probe says nothing gets one
    /// placeholder that comes and goes, and that answer is then remembered
    /// for the connection; asked on `refreshing` alone, the row was inserted
    /// and taken away again on every appearance of every screen.
    func isAwaitingFirstReading(for peer: PairedPeer) -> Bool {
        guard refreshing == peer.hostKey else { return false }
        guard let reading, reading.hostKey == peer.hostKey else { return true }
        return reading.connection != connections.connectionID(for: peer)
    }

    /// Reads the host's status, if there is a connection to read it over.
    ///
    /// Also where what the host *is* gets stored on its peer record — the same
    /// reply carries both, and that half is what the host list shows when
    /// nothing is connected.
    ///
    /// - Parameter force: read even though the last reading is fresh. A screen
    ///   appearing passes false; a pull-to-refresh passes true.
    func refresh(for peer: PairedPeer, force: Bool = false) async {
        guard let connection = connections.connectionID(for: peer) else { return }
        if !force {
            guard refreshing != peer.hostKey else { return }
            if reading?.hostKey == peer.hostKey, reading?.connection == connection,
               let readAt, .now - readAt < Self.fresh { return }
        }
        generation += 1
        let generation = generation
        refreshing = peer.hostKey
        defer { if generation == self.generation { refreshing = nil } }

        guard let output = try? await connections.shell(for: peer)
            .run(shell: HostStatusProbe.command(herdrPath: peer.herdrPath)),
            generation == self.generation
        else { return }
        let status = HostStatusProbe.status(fromOutput: output)
        peers.recordHostInfo(status.info, for: peer)
        // A reply with nothing in it is not news that the host has no memory.
        // And one that outlived its connection is about a moment that has
        // gone: the shell re-dials, so the reply can come back over a new one.
        guard connections.connectionID(for: peer) == connection else { return }
        if status.load.isEmpty, let reading, reading.hostKey == peer.hostKey,
           reading.connection == connection, !reading.load.isEmpty { return }
        // Stored even when empty, as the answer for this connection: nothing
        // is shown for it, and nothing waits for it a second time.
        reading = (peer.hostKey, connection, status.load)
        readAt = .now
    }

    #if DEBUG
    /// Seeds a reading that shows without a connection — for `#Preview` and
    /// the render tests, which have none.
    func preview(_ load: HostLoad?, for peer: PairedPeer) {
        reading = load.map { (peer.hostKey, nil, $0) }
        isPreview = true
    }
    #endif
}
