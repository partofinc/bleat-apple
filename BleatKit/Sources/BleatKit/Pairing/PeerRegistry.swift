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

    /// Where this registry writes. Exposed so a test can pin the location
    /// rather than only the behaviour — the location is the part that was
    /// wrong, and it fails on device and nowhere else.
    public var fileURL: URL { url }

    /// `~/.bleat/peers.json` — the **console tool's** location, alongside the
    /// files it has kept there since Phase 1.
    ///
    /// Not usable from an app on iOS, and the failure is not subtle: on iOS
    /// `NSHomeDirectory()` is the app's container *root*, which is read-only —
    /// only `Documents/`, `Library/` and `tmp/` inside it can be written. A
    /// pairing that had already installed and proven its key on the host then
    /// failed at the last step with `NSCocoaErrorDomain 513`, leaving a key on
    /// the host that the phone had no record of. Apps use
    /// `applicationSupport()`.
    public static func standard(
        directory: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".bleat")
    ) -> PeerRegistry {
        PeerRegistry(url: directory.appendingPathComponent("peers.json"))
    }

    /// Where an app keeps its peers: `Application Support/Bleat/peers.json`.
    ///
    /// Correct on both platforms with no branch — inside the container on iOS,
    /// under `~/Library` on a Mac — and it is the location Apple designates for
    /// data the app needs but the user does not browse.
    ///
    /// The directory is **excluded from backup**, deliberately. The device key
    /// is `ThisDeviceOnly` in the Keychain and so does not restore to a new
    /// phone; a peer list that did restore would name hosts this device can no
    /// longer authenticate to, and every one of them would fail at the
    /// handshake with nothing pointing at why. Re-pairing is the honest answer,
    /// and it is what the user has to do regardless.
    public static func applicationSupport() -> PeerRegistry {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return PeerRegistry(url: base.appendingPathComponent("Bleat/peers.json"))
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

    /// Notes where `herdr` lives, for a record that predates pairing storing it.
    ///
    /// A targeted mutation rather than `save` of an edited copy, and the
    /// difference matters: `save` merges, and merging takes the *newer*
    /// record's `lastGoodEndpoint` when it has one. An edited copy made from a
    /// peer loaded a moment earlier carries the endpoint from before this
    /// connection, so saving it would quietly undo the winner recorded on the
    /// line above.
    public func recordHerdrPath(_ path: String, forHostKey hostKey: String) throws {
        var peers = try all()
        guard let index = peers.firstIndex(where: { $0.hostKey == hostKey }) else { return }
        guard peers[index].herdrPath != path else { return }
        peers[index].herdrPath = path
        try write(peers)
    }

    /// Folds a fresh report of the host's own addresses into the stored record.
    ///
    /// A targeted mutation for the reason `recordHerdrPath` is one, and here it
    /// matters more: `save` merges, and merging takes the *newer* record's
    /// `lastGoodEndpoint`. A copy edited from a peer loaded before this
    /// connection carries the previous winner, so saving it would undo the one
    /// just recorded — and this runs moments after `recordSuccess`.
    ///
    /// - Returns: the record as stored, or nil for an unknown peer. Like
    ///   `recordSuccess`, an unknown peer is silence rather than an error: this
    ///   runs on the success path of a connection, in the background, and a
    ///   peer removed while it was in flight is a race with no consequence.
    @discardableResult
    public func recordDiscoveredEndpoints(
        _ discovered: [Endpoint],
        forHostKey hostKey: String
    ) throws -> PairedPeer? {
        var peers = try all()
        guard let index = peers.firstIndex(where: { $0.hostKey == hostKey }) else { return nil }
        let refreshed = peers[index].refreshingEndpoints(discovered: discovered)
        guard refreshed != peers[index] else { return peers[index] }
        peers[index] = refreshed
        try write(peers)
        return refreshed
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
        var directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // See `applicationSupport()`: the device key cannot restore to another
        // phone, so a peer list that did would name hosts this device can no
        // longer reach. Set on the directory, and harmless where backup does
        // not apply.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(peers).write(to: url, options: .atomic)
    }
}
