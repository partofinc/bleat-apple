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
        let connection = try await PeerConnector.connect(
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

        var discovered: String?
        if peer.herdrPath == nil {
            // Only reachable for a record made before pairing resolved this.
            // Asking now costs one command on a connection that is already
            // open, where rebuilding the transport would cost a handshake.
            do {
                let output = try await connection.transport.run(shell: HerdrLookup.command)
                guard let path = HerdrLookup.path(inOutput: output) else {
                    throw PairingError.herdrNotFound
                }
                connection.transport.useHerdrPath(path)
                discovered = path
            } catch {
                // Every throw, not just the not-found one. This connection is
                // the only reference to a live SSH session — a failed command
                // does not close the channel, and neither does cancellation —
                // so unwinding without disconnecting leaves a session open on
                // the host, and each retry adds another.
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
