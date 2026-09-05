import Foundation

/// The phone's paired hosts, on disk.
///
/// Keyed by host key, because that is what a peer *is*: the same machine
/// answers with the same key on every address it listens on, so pairing the
/// same Mac again from a different network merges endpoints into the record
/// that exists rather than creating a second one. `HostRegistry` keys by a
/// user-chosen name and cannot do that — it predates pairing and stays as the
/// console tool's own list.
///
/// JSON in the app container on iOS, `~/.bleat/` on a Mac, matching
/// `HostRegistry` and `KnownHostsStore`. Nothing secret lives here: the device
/// key is in the Keychain, and a host key is public by definition.
///
/// A *registry*, not a store, for the same reason `HostRegistry` is: it is the
/// file. `PeerStore` in `BleatUI` is the observable that wraps it, and the
/// naming pair is what says which is which.
public struct PeerRegistry: Sendable {
    private let url: URL

    public init(url: URL) { self.url = url }

    public static func standard(
        directory: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".bleat")
    ) -> PeerRegistry {
        PeerRegistry(url: directory.appendingPathComponent("peers.json"))
    }

    public func all() throws -> [PairedPeer] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return try JSONDecoder().decode([PairedPeer].self, from: data)
    }

    public func peer(hostKey: String) throws -> PairedPeer? {
        try all().first { $0.hostKey == hostKey }
    }

    /// Adds a peer, or folds it into the one that already has that host key.
    ///
    /// - Returns: the record as stored, which for a re-pairing is the merge
    ///   rather than the argument — the caller wants the endpoints it did not
    ///   just learn as well as the ones it did.
    @discardableResult
    public func save(_ peer: PairedPeer) throws -> PairedPeer {
        var peers = try all()
        let merged: PairedPeer
        if let index = peers.firstIndex(where: { $0.hostKey == peer.hostKey }) {
            merged = try peers[index].merging(peer)
            peers[index] = merged
        } else {
            merged = peer
            peers.append(merged)
        }
        try write(peers)
        return merged
    }

    /// Records the endpoint that last completed a handshake, so the next
    /// connection tries it first instead of racing every address again.
    ///
    /// Silently does nothing for an unknown peer: this is called on the success
    /// path of a connection, and failing there would turn a working connection
    /// into an error over bookkeeping.
    public func recordSuccess(endpoint: Endpoint, forHostKey hostKey: String) throws {
        var peers = try all()
        guard let index = peers.firstIndex(where: { $0.hostKey == hostKey }) else { return }
        guard peers[index].lastGoodEndpoint != endpoint else { return }
        peers[index].lastGoodEndpoint = endpoint
        try write(peers)
    }

    /// Forgets a peer.
    ///
    /// This does **not** remove the device key from the host — nothing here can
    /// reach it, and a phone that has been un-paired is usually one that cannot
    /// connect any more. The key on the host carries a `bleat-device-` marker
    /// so it can be found and deleted from the Mac side.
    ///
    /// - Returns: `false` when no peer had that host key.
    @discardableResult
    public func remove(hostKey: String) throws -> Bool {
        let peers = try all()
        let remaining = peers.filter { $0.hostKey != hostKey }
        guard remaining.count != peers.count else { return false }
        try write(remaining)
        return true
    }

    private func write(_ peers: [PairedPeer]) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(peers).write(to: url, options: .atomic)
    }
}
