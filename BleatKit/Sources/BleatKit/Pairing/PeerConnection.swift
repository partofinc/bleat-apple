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
            throw TransportError.connectionFailed(
                link.onLocalLink
                    ? "this host has no known address"
                    : "this host is only reachable on its local network — join "
                        + "that network, connect a VPN that reaches it, or add "
                        + "an address that works from here"
            )
        }

        // The only caller that vouches for this: `endpoints` is what survived
        // `endpointsToTry`, so anything unroutable from here has already been
        // ruled out and "all that is left is the tunnel" is a fact rather than
        // an accident of what the caller happened to pass.
        //
        // …and only off the local link. On Wi-Fi nothing was dropped as
        // unroutable, so a private address that failed there means the host is
        // off or asleep — not that a VPN needs checking.
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
            droppedUnroutable: !link.onLocalLink
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
