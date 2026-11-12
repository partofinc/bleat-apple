import Foundation

/// Turns a paired peer into a working `HerdrClient`.
///
/// This is where the pairing record finally pays off. Everything the connection
/// needs was learned once, out of band: which machine this is (the host key),
/// where it answers (the endpoints), who to log in as, and where `herdr` lives
/// on it. Nothing here prompts, guesses, or trusts anything on first sight.
public enum PeerConnection {
    public struct Connected: Sendable {
        public let client: HerdrClient
        public let transport: SSHTransport
        /// The address that won. Worth writing back to the peer: it is nearly
        /// always still right, and trying it alone beats racing again.
        public let endpoint: Endpoint
        /// Non-nil only when the path had to be discovered — a peer paired
        /// before `herdrPath` was recorded. The caller should persist it.
        public let discoveredHerdrPath: String?
    }

    /// The SSH half of `connect`: races the peer's endpoints and returns the
    /// winning transport, with no `herdr` call on it.
    ///
    /// Separate so that something can ask a host a plain shell question without
    /// first needing herdr to be there — `HerdrCoreCheck` asks whether `hc` is
    /// installed, on hosts where herdr may already be gone.
    ///
    /// - Throws: `TransportError.connectionFailed` when nothing answered, or
    ///   `.hostKeyMismatch` when something answered and was not this peer.
    public static func open(
        to peer: PairedPeer,
        deviceKey: SSHKeyPair,
        link: LinkState,
        session: String? = nil
    ) async throws -> PeerConnector.Connection {
        let endpoints = peer.endpointsToTry(from: link)
        guard !endpoints.isEmpty else {
            // Distinguished from "nothing answered": the addresses were not
            // tried, they were ruled out, and the remedy is a different network
            // rather than a running host.
            guard !link.onLocalLink else {
                throw TransportError.connectionFailed("this host has no known address")
            }
            // Whether a VPN could help depends on what was ruled out, and
            // offering one where it cannot is the mistake this whole change is
            // about avoiding. A private address is routable through a tunnel
            // that carries the subnet; an mDNS name is not, because multicast
            // does not leave the link — so a peer known only by its `.local`
            // name must not be answered with "connect a VPN".
            let aTunnelCouldHelp = peer.endpoints.contains { $0.reach == .privateAddress }
            throw TransportError.connectionFailed(
                aTunnelCouldHelp
                    ? "this host is only reachable on its local network — join that "
                        + "network, or connect a VPN that routes it"
                    : "this host is only reachable by a name that works only on its "
                        + "own network — join that network, or add an address that "
                        + "works from here"
            )
        }

        // The only caller that can answer this: `endpoints` is what survived
        // `endpointsToTry`, so anything unreachable from here has already been
        // ruled out — and `needsTunnel(from:)` is link-dependent, which is the
        // part `PeerConnector` cannot work out for itself. A mesh address
        // always needs the tunnel, including on Wi-Fi; an ordinary private one
        // needs it only off the local link, where it is a candidate at all only
        // because a tunnel was detected.
        return try await PeerConnector.connect(
            endpoints: endpoints,
            username: peer.username,
            hostKey: peer.hostKey,
            privateKey: deviceKey,
            // `"herdr"` is the placeholder the transport starts with; every
            // `herdr` call would fail on it, which is why the path is settled
            // before a client is handed out.
            herdrPath: peer.herdrPath ?? "herdr",
            session: session ?? peer.session,
            everyCandidateNeedsATunnel: endpoints.allSatisfy { $0.needsTunnel(from: link) }
        )
    }

    /// Races the peer's endpoints and returns a client on the winner.
    ///
    /// - Parameter link: Where the phone is standing. Endpoints that provably
    ///   cannot work from there are dropped rather than ordered last, since
    ///   attempting one only spends the timeout — `endpointsToTry` applies it.
    /// - Throws: `TransportError.connectionFailed` when nothing answered, or
    ///   `.hostKeyMismatch` when something answered and was not this peer.
    public static func connect(
        to peer: PairedPeer,
        deviceKey: SSHKeyPair,
        link: LinkState,
        session: String? = nil
    ) async throws -> Connected {
        let connection = try await open(to: peer, deviceKey: deviceKey, link: link, session: session)

        var discovered: String?
        // Not asked at all of a peer with herdr-core: nothing Bleat 2 runs
        // there needs herdr, and asking would cost a round trip per connection.
        if peer.herdrPath == nil, !(peer.herdrCore?.isInstalled ?? false) {
            // Best effort, and never a reason to refuse the connection. Bleat
            // 2 reaches hosts through herdr-core, and a host paired on hc may
            // have no herdr at all: refusing it here also refused unpairing,
            // the host's settings and its load, which all ride this connection.
            // A failed command does leave the channel open, and cancellation
            // does too, so a throw still disconnects before it propagates.
            do {
                let output = try await connection.transport.run(shell: HerdrLookup.command)
                if let path = HerdrLookup.path(inOutput: output) {
                    connection.transport.useHerdrPath(path)
                    discovered = path
                }
            } catch {
                await connection.transport.disconnect()
                throw error
            }
        }

        return Connected(
            client: HerdrClient(transport: connection.transport),
            transport: connection.transport,
            endpoint: connection.endpoint,
            discoveredHerdrPath: discovered
        )
    }
}
