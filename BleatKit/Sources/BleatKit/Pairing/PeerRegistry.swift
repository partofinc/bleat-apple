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
        _ discovered: EndpointDiscovery.Report,
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

    /// Adds an address the user supplied, which detection could not find.
    ///
    /// The backstop for everything the other two paths miss. A zero-trust
    /// overlay's private DNS name is the motivating case — nothing on the host
    /// knows it, so no refresh can ever discover it — but it equally covers a
    /// port-forward, a jump address, and a host that has moved somewhere the
    /// phone cannot reach until it is told where.
    ///
    /// Deliberately **not** recorded in `hostReport`, which is what
    /// makes it sticky: a refresh may only prune what the host once claimed, so
    /// an address the host has never mentioned survives every refresh. That is
    /// the whole point — it was added precisely because detection cannot see
    /// it.
    ///
    /// - Returns: nil for an unknown peer or an address already present. A
    ///   duplicate is not an error; the address the user wanted is there.
    @discardableResult
    public func addEndpoint(_ endpoint: Endpoint, forHostKey hostKey: String) throws -> PairedPeer? {
        var peers = try all()
        guard let index = peers.firstIndex(where: { $0.hostKey == hostKey }) else { return nil }
        guard !peers[index].endpoints.contains(endpoint) else { return peers[index] }
        peers[index].endpoints.append(endpoint)
        try write(peers)
        return peers[index]
    }

    /// Remembers that this phone started `session` on the host.
    ///
    /// A targeted mutation for the reason `recordHerdrPath` is one: `save`
    /// merges, and a merge takes the newer record's `lastGoodEndpoint` — this
    /// runs moments after `recordSuccess`, so writing back an edited copy
    /// loaded a moment earlier would undo the endpoint that had just won.
    @discardableResult
    public func recordCreatedSession(_ session: String, forHostKey hostKey: String) throws -> PairedPeer? {
        var peers = try all()
        guard let index = peers.firstIndex(where: { $0.hostKey == hostKey }) else { return nil }
        guard !peers[index].createdHere(session) else { return peers[index] }
        peers[index].createdSessions = (peers[index].createdSessions ?? []) + [session]
        try write(peers)
        return peers[index]
    }

    /// Records that this phone is why `session` is running, which is what the
    /// stop confirmation reads. See `PairedPeer.startedSessions`.
    @discardableResult
    public func recordStartedSession(_ session: String, forHostKey hostKey: String) throws -> PairedPeer? {
        var peers = try all()
        guard let index = peers.firstIndex(where: { $0.hostKey == hostKey }) else { return nil }
        guard !peers[index].startedHere(session) else { return peers[index] }
        peers[index].startedSessions = (peers[index].startedSessions ?? []) + [session]
        try write(peers)
        return peers[index]
    }

    /// Drops that claim once the session is down again.
    ///
    /// **Called on stop, and this is what keeps the claim honest.** It means
    /// "this phone is why it is running", so a session that is no longer
    /// running has no such reason. Left standing, starting and stopping the
    /// user's own `work` session from the phone would leave a permanent claim on
    /// that name — and the stop confirmation would then describe whatever they
    /// started next under it as this phone's own doing.
    @discardableResult
    public func forgetStartedSession(_ session: String, forHostKey hostKey: String) throws -> PairedPeer? {
        var peers = try all()
        guard let index = peers.firstIndex(where: { $0.hostKey == hostKey }) else { return nil }
        guard peers[index].startedHere(session) else { return peers[index] }
        let remaining = (peers[index].startedSessions ?? []).filter { $0 != session }
        peers[index].startedSessions = remaining.isEmpty ? nil : remaining
        try write(peers)
        return peers[index]
    }

    /// Forgets a session this phone started, once it is gone from the host.
    ///
    /// **Called on delete, and that is not bookkeeping.** The name is the only
    /// thing tying a session to this install, so a name left in the list
    /// outlives the session it referred to — and the next session of that name,
    /// made by whoever is at the Mac, would inherit the Delete action as if the
    /// phone had created it. Deleting is exactly when the claim stops being
    /// true.
    @discardableResult
    public func forgetCreatedSession(_ session: String, forHostKey hostKey: String) throws -> PairedPeer? {
        var peers = try all()
        guard let index = peers.firstIndex(where: { $0.hostKey == hostKey }) else { return nil }
        guard peers[index].createdHere(session) || peers[index].startedHere(session) else {
            return peers[index]
        }
        let remaining = (peers[index].createdSessions ?? []).filter { $0 != session }
        peers[index].createdSessions = remaining.isEmpty ? nil : remaining
        // A deleted session is not running either, so the other claim goes with
        // it — otherwise a session of that name made later at the Mac would be
        // described by the stop confirmation as one this phone had started.
        let started = (peers[index].startedSessions ?? []).filter { $0 != session }
        peers[index].startedSessions = started.isEmpty ? nil : started
        try write(peers)
        return peers[index]
    }

    /// Removes an address the user no longer wants dialled.
    ///
    /// Mostly for what a refresh cannot prune: an endpoint that came from the
    /// QR was never attributed to the host's self-report, so it is sticky, and
    /// a stale one would otherwise be raced on every connection forever.
    ///
    /// **`lastGoodEndpoint` is cleared when it is the one being removed**, and
    /// this is load-bearing rather than tidiness. `refreshingEndpoints` puts the
    /// last-good address back into the list unconditionally — it completed a
    /// handshake, which outranks any report — so leaving the field pointing at
    /// a deleted address would have the next refresh silently restore it, and
    /// the removal would appear to undo itself minutes later.
    ///
    /// The **last** endpoint cannot be removed. A peer with none is
    /// unreachable and unrepairable from the phone: there is nothing left to
    /// connect over, so nothing can add one back, and the only way out is a
    /// walk to the Mac. Unpairing is the deliberate way to be rid of a peer.
    ///
    /// An address the host still reports **will come back on the next
    /// refresh**, and that is correct: the host is saying it answers there.
    /// A tombstone would make removal stick, at the cost of a way to blind the
    /// app permanently to a working address; racing one extra endpoint
    /// concurrently is much the cheaper mistake.
    ///
    /// - Returns: nil when the peer is unknown, the address is not on it, or it
    ///   is the only one left.
    @discardableResult
    public func removeEndpoint(_ endpoint: Endpoint, forHostKey hostKey: String) throws -> PairedPeer? {
        var peers = try all()
        guard let index = peers.firstIndex(where: { $0.hostKey == hostKey }) else { return nil }
        guard peers[index].endpoints.contains(endpoint), peers[index].endpoints.count > 1 else {
            return nil
        }
        peers[index].endpoints.removeAll { $0 == endpoint }
        if peers[index].lastGoodEndpoint == endpoint { peers[index].lastGoodEndpoint = nil }
        try write(peers)
        return peers[index]
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
