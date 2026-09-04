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
    /// `SHA256:…` for the host key. The identity, and the primary key.
    public let hostKeyFingerprint: String
    public var name: String
    public var username: String
    /// Ordered by preference. `endpoint(for:)` decides what to try.
    public var endpoints: [Endpoint]
    public var herdrPath: String
    /// Whichever endpoint last completed a handshake. Tried first next time.
    public var lastGoodEndpoint: Endpoint?
    /// Session to select by default, once the user has picked one.
    public var session: String?

    public var id: String { hostKeyFingerprint }

    public init(
        hostKeyFingerprint: String,
        name: String,
        username: String,
        endpoints: [Endpoint],
        herdrPath: String,
        lastGoodEndpoint: Endpoint? = nil,
        session: String? = nil
    ) {
        self.hostKeyFingerprint = hostKeyFingerprint
        self.name = name
        self.username = username
        self.endpoints = endpoints
        self.herdrPath = herdrPath
        self.lastGoodEndpoint = lastGoodEndpoint
        self.session = session
    }

    public init(payload: PairingPayload) {
        self.init(
            hostKeyFingerprint: payload.hostKeyFingerprint,
            name: payload.name,
            username: payload.username,
            endpoints: payload.endpoints,
            herdrPath: payload.herdrPath
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
        guard other.hostKeyFingerprint == hostKeyFingerprint else {
            throw PairingError.hostKeyMismatch(
                expected: hostKeyFingerprint, actual: other.hostKeyFingerprint
            )
        }
        var merged = self
        merged.name = other.name
        merged.username = other.username
        merged.herdrPath = other.herdrPath
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
