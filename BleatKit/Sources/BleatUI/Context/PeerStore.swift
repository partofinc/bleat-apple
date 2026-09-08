import BleatKit
import Observation

/// The paired hosts, as the UI sees them, plus the key this device pairs with.
///
/// Wraps `PeerRegistry` (the file) and `KeychainKeyStore` (the key) rather than
/// re-implementing either, so the phone and the console tool agree on the
/// format of a peer record. The naming pair is the same one `HostRegistry` and
/// the old `HostStore` used: registry is the file, store is the observable.
///
/// It replaces the manual host list. That list existed because there was no way
/// to acquire a host except by typing one in; pairing is the way now, and the
/// product promise is zero host setup beyond Herdr.
@Observable
public final class PeerStore {
    public private(set) var peers: [PairedPeer] = []
    /// Set when loading or saving failed, for a view to surface. Nothing here
    /// throws into a view body.
    public private(set) var failure: String?

    private let registry: PeerRegistry
    private let keys: KeychainKeyStore

    /// - Parameter registry: Defaults to the **app's** location, not the
    ///   console tool's. `PeerRegistry.standard()` is `~/.bleat`, which on iOS
    ///   resolves inside the app container's read-only root and cannot be
    ///   written at all.
    public init(
        registry: PeerRegistry = .applicationSupport(),
        keys: KeychainKeyStore = KeychainKeyStore()
    ) {
        self.registry = registry
        self.keys = keys
    }

    public func reload() {
        do {
            peers = try registry.all()
            failure = nil
        } catch {
            // Deliberately not `peers = []`: an unreadable file is a reason to
            // say so, not a reason to tell the user their hosts are gone.
            failure = String(describing: error)
        }
    }

    public func remove(_ peer: PairedPeer) {
        do {
            try registry.remove(hostKey: peer.hostKey)
            reload()
        } catch {
            failure = String(describing: error)
        }
    }

    /// Pairs with a scanned code and records what came back.
    ///
    /// `PairingClient.pair` is `nonisolated async`, so the SSH work runs off the
    /// main actor; only the reload afterwards is back here.
    ///
    /// - Throws: `PairingError`, which every case of describes itself well
    ///   enough to show the user directly.
    public func pair(withCode code: String) async throws -> PairedPeer {
        let client = PairingClient(peers: registry, deviceKey: try deviceKey())
        let peer = try await client.pair(withCode: code)
        reload()
        return peer
    }

    /// Notes the address that just worked, so the next connection tries it
    /// first rather than racing every address again.
    ///
    /// Silently does nothing on failure. This is called on the success path of
    /// a connection, and throwing there would turn a working connection into an
    /// error over bookkeeping.
    public func recordSuccess(endpoint: Endpoint, for peer: PairedPeer) {
        try? registry.recordSuccess(endpoint: endpoint, forHostKey: peer.hostKey)
        reload()
    }

    /// Stores a `herdr` path that had to be discovered, so the next connection
    /// does not have to ask again. Only happens for a peer paired before the
    /// path was recorded.
    public func recordHerdrPath(_ path: String, for peer: PairedPeer) {
        try? registry.recordHerdrPath(path, forHostKey: peer.hostKey)
        reload()
    }

    /// Asks the host what its addresses are now, and folds the answer in.
    ///
    /// **Why this exists:** endpoints were captured once, at pair time, and
    /// never looked at again. A Mac that moved to a new network, a Tailscale
    /// node removed and re-added, a tunnel set up after pairing — each of them
    /// cost a full re-pair, walking back to the Mac to run `bleat pair`. The
    /// host is the authority on its own addresses and the phone is already
    /// talking to it, so asking costs three exec channels on a connection that
    /// is already open.
    ///
    /// It is a hedge, not a guarantee, and worth being honest about: a refresh
    /// only happens over a connection that still works, so a host whose every
    /// stored endpoint died at once is still a re-pair. What this removes is
    /// the far more common case where *one* of them changed.
    ///
    /// Deliberately silent on every failure. Nothing here is worth showing a
    /// user — they did not ask for it, and the whole of the downside is that
    /// the endpoints stay as they were.
    /// The port comes from `PairedPeer.discoveryPort` — the port this peer
    /// already associates with the host — because discovery reports addresses
    /// and never ports. Neither the endpoint that won the race nor the previous
    /// `lastGoodEndpoint` will do: either can be a manually added port forward,
    /// and stamping every discovered address with its external port supersedes
    /// the ones that actually work.
    public func refreshEndpoints(for peer: PairedPeer, over shell: any ShellRunner) async {
        let discovered = await EndpointDiscovery.probe(shell, port: peer.discoveryPort)
        // No probe answered — the host was unaskable, or this task was
        // cancelled part way. Either way there is nothing to say about its
        // addresses, and saying it anyway would prune against silence.
        guard discovered.answered, !Task.isCancelled else { return }
        _ = try? registry.recordDiscoveredEndpoints(discovered, forHostKey: peer.hostKey)
        reload()
    }

    /// Adds an address the user typed in.
    ///
    /// - Returns: whether the address is on the peer afterwards — which is
    ///   `true` for one that was already there, since that is the outcome the
    ///   user asked for and the sheet should close either way. Only a failed
    ///   write returns `false`, and it is the sheet's cue to stay open and say
    ///   so. Deliberately not "whether anything was written": a background
    ///   refresh can add the very address being typed while the sheet is open,
    ///   and reporting that as a failure would be a lie about a peer that has
    ///   exactly what was wanted.
    @discardableResult
    public func addEndpoint(_ endpoint: Endpoint, to peer: PairedPeer) -> Bool {
        do {
            let stored = try registry.addEndpoint(endpoint, forHostKey: peer.hostKey)
            reload()
            return stored != nil
        } catch {
            failure = String(describing: error)
            return false
        }
    }

    /// Removes an address. Refuses to remove the last one — see
    /// `PeerRegistry.removeEndpoint`.
    @discardableResult
    public func removeEndpoint(_ endpoint: Endpoint, from peer: PairedPeer) -> Bool {
        do {
            let stored = try registry.removeEndpoint(endpoint, forHostKey: peer.hostKey)
            reload()
            return stored != nil
        } catch {
            failure = String(describing: error)
            return false
        }
    }

    // MARK: - Device key

    /// The device's key, created on first read.
    ///
    /// Throws rather than writing to `failure`, which belongs to the peer list.
    /// Sharing one error property meant opening the key sheet *cleared* an
    /// unreadable-peer-file banner, and `PeersView` then said "No hosts yet" —
    /// confidently wrong, and it invites a pairing that will fail at the last
    /// step on the same unreadable file.
    public func deviceKey() throws -> SSHKeyPair {
        try keys.loadOrCreate()
    }
}
