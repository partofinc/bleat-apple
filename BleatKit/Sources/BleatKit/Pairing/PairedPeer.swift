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
        session: String? = nil
    ) {
        self.hostKey = hostKey
        self.name = name
        self.username = username
        self.endpoints = endpoints
        self.herdrPath = herdrPath
        self.lastGoodEndpoint = lastGoodEndpoint
        self.deviceMarker = deviceMarker
        self.session = session
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
        return merged
    }

    /// The endpoints to try, in order, given where the phone is standing.
    ///
    /// Last-known-good goes first — it is nearly always still right, and trying
    /// it alone avoids opening several connections for nothing. When the phone
    /// is off the local link, `.local` names and RFC1918 addresses are dropped
    /// entirely rather than ordered last: they cannot resolve or route from
    /// there, so attempting them only spends the timeout budget.
    public func endpointsToTry(onLocalLink: Bool) -> [Endpoint] {
        let candidates = onLocalLink ? endpoints : endpoints.filter(\.isUsableOffLink)
        guard let last = lastGoodEndpoint, candidates.contains(last) else { return candidates }
        return [last] + candidates.filter { $0 != last }
    }
}
