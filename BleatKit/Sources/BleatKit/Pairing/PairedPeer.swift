import Foundation

/// A host the phone has paired with.
///
/// **Identity is the host key, not the address.** The same machine answers with
/// the same host key on every endpoint it listens on — verified over loopback,
/// `.local` and a LAN address, all returning one fingerprint. So a machine
/// reachable both on the LAN and over Tailscale is *one* peer with two
/// endpoints, not two peers, and pairing again from a different network merges
/// rather than duplicating.
public struct PairedPeer: Sendable, Codable, Equatable, Identifiable {
    /// The host key in OpenSSH `<algorithm> <base64>` form — the identity, and
    /// what `KnownHostsStore` pins and compares.
    public let hostKey: String
    public var name: String
    public var username: String
    /// Ordered by preference. `endpoint(for:)` decides what to try.
    public var endpoints: [Endpoint]
    /// Absolute path to `herdr`, resolved on the host.
    ///
    /// Optional because it no longer travels in the QR: the phone resolves it
    /// with `command -v herdr` through a login shell on first connect, so it is
    /// nil on a peer that has been paired but not yet used. A path that cannot
    /// go stale is worth the round trip, and it saved 24 bytes of QR.
    public var herdrPath: String?
    /// Whichever endpoint last completed a handshake. Tried first next time.
    public var lastGoodEndpoint: Endpoint?
    /// The marker on this device's line in the host's `authorized_keys`, e.g.
    /// `bleat-device-1a2b3c4d5e6f7a8b`.
    ///
    /// Kept so that unpairing can tell the user exactly which line to remove
    /// when it cannot remove it itself — `bleat keys revoke <marker>` is a
    /// command they can copy, where "find the Bleat key" is a hunt. `Enrollment`
    /// has always minted this and `PairingClient` used to throw it away.
    ///
    /// Optional because a record can predate it, and because it is a
    /// *convenience*, never an identity: revocation itself matches on the key,
    /// which the phone always holds and which cannot go stale.
    public var deviceMarker: String?
    /// Session to select by default, once the user has picked one.
    public var session: String?

    /// The host's most recent report about its own addresses, kept per probe.
    ///
    /// **`nil` is not an empty report, and the difference is what makes a
    /// refresh safe.** `nil` means this record has never been refreshed — every
    /// endpoint on it came from the QR, and none can be attributed to the
    /// host's self-report, so a refresh may add but must not prune. A stored
    /// report is a set the phone watched the host produce, so anything in it
    /// the host no longer reports has genuinely gone.
    ///
    /// Kept so a refresh can tell an address the host has dropped from one it
    /// never claimed. The second kind is sticky: a private DNS name given with
    /// `--endpoint`, or anything added by hand, is invisible to detection, and
    /// pruning it for being absent from a report that could never have
    /// contained it would delete the one endpoint that works for a zero-trust
    /// overlay.
    ///
    /// Per probe rather than one flat set, because a probe that fails must not
    /// look like a category the host has emptied — see
    /// `EndpointDiscovery.Report`, where that distinction is the difference
    /// between a stopped Tailscale and a peer that can never be reached again.
    public var hostReport: EndpointDiscovery.Report?

    public var id: String { hostKey }

    /// `SHA256:…` for showing the user. Never used for comparison.
    public var hostKeyFingerprint: String? { SSHPublicKeyLine(line: hostKey)?.fingerprint }

    public init(
        hostKey: String,
        name: String,
        username: String,
        endpoints: [Endpoint],
        herdrPath: String? = nil,
        lastGoodEndpoint: Endpoint? = nil,
        deviceMarker: String? = nil,
        session: String? = nil,
        hostReport: EndpointDiscovery.Report? = nil
    ) {
        self.hostKey = hostKey
        self.name = name
        self.username = username
        self.endpoints = endpoints
        self.herdrPath = herdrPath
        self.lastGoodEndpoint = lastGoodEndpoint
        self.deviceMarker = deviceMarker
        self.session = session
        self.hostReport = hostReport
    }

    public init(payload: PairingPayload) {
        self.init(
            hostKey: payload.hostKey,
            name: payload.name,
            username: payload.username,
            endpoints: payload.endpoints
        )
    }

    /// Folds a fresh pairing of the same machine into this record.
    ///
    /// New endpoints are appended rather than replacing the list: pairing over
    /// Tailscale must not cost the peer its LAN addresses, which are the fast
    /// path when the phone is home. Mutable details (name, username, herdr
    /// path) take the newer value, since the tool just read them off the host.
    ///
    /// - Throws: `PairingError.hostKeyMismatch` when `other` describes a
    ///   different host key. Merging across identities would graft one
    ///   machine's addresses onto another, so it is refused — but as a
    ///   reportable error, not a trap: `other` is built straight from a scanned
    ///   QR, and a mismatched scan must show the user a message rather than
    ///   crash the app.
    public func merging(_ other: PairedPeer) throws -> PairedPeer {
        guard other.hostKey == hostKey else {
            throw PairingError.hostKeyMismatch(expected: hostKey, actual: other.hostKey)
        }
        var merged = self
        merged.name = other.name
        merged.username = other.username
        // Keep a path we already resolved if the newer record has none.
        merged.herdrPath = other.herdrPath ?? herdrPath
        // Likewise the endpoint that just worked. Keeping the stored one would
        // send the next connection to the network the phone has left: re-pair a
        // laptop over Tailscale and the LAN address it answered on last week is
        // tried first, and its timeout is spent before anything else is. Seen
        // in a live run — a re-pairing reported the previous winner as the one
        // it had just reached.
        merged.lastGoodEndpoint = other.lastGoodEndpoint ?? lastGoodEndpoint
        // The newer marker wins outright when there is one, because re-pairing
        // *replaced* the line: `replaceKeyCommand` drops every line carrying
        // this key and appends one under a freshly minted marker. Keeping the
        // old value would print a revoke command naming a line that is no
        // longer in the file.
        merged.deviceMarker = other.deviceMarker ?? deviceMarker
        for endpoint in other.endpoints where !merged.endpoints.contains(endpoint) {
            merged.endpoints.append(endpoint)
        }
        if let session = other.session { merged.session = session }
        merged.hostReport = other.hostReport ?? hostReport
        return merged
    }

    /// Folds a fresh report of the host's own addresses into this record.
    ///
    /// Runs after a successful connection, over the connection that just
    /// succeeded — so it is exactly as trustworthy as the host key pin that
    /// authenticated it, which is what lets it happen silently with nothing to
    /// confirm.
    ///
    /// Four rules, and each of them is a way this would otherwise go wrong:
    ///
    /// - **A report where no probe answered changes nothing.** That is the host
    ///   being unaskable — an older macOS without `scutil`, a restricted shell,
    ///   a cancelled refresh — and not the host saying it has no addresses.
    ///   Treating it as one would empty the peer and strand the phone with a
    ///   record it can never connect through again.
    /// - **Pruning is per probe, not per report.** Only categories the host
    ///   actually answered for may lose entries. Flattened, a `tailscale` that
    ///   timed out — or is merely switched off, which is not an error at all —
    ///   would look like a host that had dropped every overlay endpoint, and
    ///   one pass would delete the MagicDNS name and both tunnel addresses.
    ///   The next time the phone left Wi-Fi the host would be gone for good.
    /// - **Only what the host previously claimed may be pruned.** Everything
    ///   else is sticky: entries from the QR, `--endpoint` extras, anything
    ///   added by hand. Detection cannot see them, so their absence from a
    ///   report is not evidence of anything.
    /// - **`lastGoodEndpoint` survives, for one refresh.** It completed a
    ///   handshake minutes ago, which outranks any report about it. Putting it
    ///   back is recorded in `Report.reinstated` so the exemption expires:
    ///   unrecorded, it would read as an address the host never claimed and
    ///   become permanently un-prunable, so a recycled DHCP lease that won one
    ///   race would live in the peer forever.
    ///
    /// Pruning matters as much as adding, and this is the half that is easy to
    /// skip. A list that only ever grows accumulates recycled DHCP leases and
    /// dead node addresses, and each one is dialled on every connection from
    /// then on. Worse than the wasted slot: a recycled address reaches an
    /// unrelated machine, which fails *host key verification* — and
    /// `PeerConnector` promotes a mismatch over every other failure, so a
    /// sleeping Mac plus one stale address reports a security warning instead
    /// of "could not reach it". `InterfaceAddresses.ignoredPrefixes` exists to
    /// avoid the identical hazard from virtual interfaces.
    public func refreshingEndpoints(discovered: EndpointDiscovery.Report) -> PairedPeer {
        guard discovered.answered else { return self }
        var updated = self
        let previous = hostReport ?? EndpointDiscovery.Report()
        let superseded = previous.superseded(by: discovered)
        var kept = endpoints.filter { !superseded.contains($0) }
        for endpoint in discovered.all where !kept.contains(endpoint) {
            kept.append(endpoint)
        }
        var report = previous.merging(discovered)
        // After the merge, not before: the winner may be one the host has just
        // stopped reporting, and it is still the only address demonstrated to
        // work from where this phone is standing. Recorded, so the next refresh
        // may take it away once it is no longer the winner.
        if let last = lastGoodEndpoint, !kept.contains(last) {
            kept.append(last)
            report.reinstated = [last]
        }
        updated.endpoints = kept
        updated.hostReport = report
        return updated
    }

    /// The port to stamp a freshly discovered address with.
    ///
    /// **Discovery yields addresses, never ports.** `scutil`, `ifconfig` and
    /// `tailscale` all report where a machine can be found and none of them
    /// knows what port its sshd binds — that was settled once, by
    /// `bleat pair --port`. So a refresh must not invent one; it has to reuse
    /// the port this peer already associates with the host, and the most common
    /// port across its endpoints is that answer.
    ///
    /// **The obvious alternative strands the peer.** Taking the port of the
    /// endpoint that just won the race looks right — it demonstrably reached
    /// sshd — but the winner can be a manually added port forward, which is the
    /// motivating case for adding one at all. A peer with `mac.local:22`,
    /// `192.168.1.20:22` and `100.114.119.30:22` plus a hand-typed
    /// `home.example.com:2222` connects over the forward from cellular; the
    /// refresh then rebuilds every discovered address at 2222 and supersedes
    /// the three that worked. Back on Wi-Fi every endpoint refuses, and since
    /// no connection succeeds no later refresh can repair it. A re-pair, caused
    /// by using the feature as documented.
    ///
    /// Ties break towards the lower port, so the answer is stable rather than
    /// depending on dictionary order.
    public var discoveryPort: Int {
        var counts: [Int: Int] = [:]
        for endpoint in endpoints { counts[endpoint.port, default: 0] += 1 }
        guard let best = counts.max(by: { ($0.value, $1.key) < ($1.value, $0.key) })?.key else {
            return Endpoint.defaultPort
        }
        return best
    }

    /// The endpoints to try, in order, given where the phone is standing.
    ///
    /// Last-known-good goes first — it is nearly always still right, and trying
    /// it alone avoids opening several connections for nothing. Anything that
    /// provably cannot work from here is dropped entirely rather than ordered
    /// last, since attempting it only spends the timeout budget; `link` is what
    /// decides, and `Endpoint.isUsable(from:)` holds the rule.
    public func endpointsToTry(from link: LinkState) -> [Endpoint] {
        let candidates = endpoints.filter { $0.isUsable(from: link) }
        guard let last = lastGoodEndpoint, candidates.contains(last) else { return candidates }
        return [last] + candidates.filter { $0 != last }
    }
}
