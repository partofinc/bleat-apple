import Crypto
import Foundation

/// Opens a connection to a peer, given several addresses it might answer on.
///
/// A peer is one host key and an ordered list of endpoints, so connecting means
/// picking one. Trying them in order is the obvious approach and the wrong one:
/// the first entry is usually a `.local` name, which off the LAN does not fail
/// so much as sit there, and the working Tailscale address behind it never gets
/// a turn. So they are **raced**, and the first handshake to complete wins.
///
/// Whichever endpoint wins, the host key is checked against the one supplied.
/// The endpoint is a hint; the key is the identity.
public enum PeerConnector {
    /// One endpoint's outcome. Failures are carried rather than dropped: which
    /// way an attempt failed is the difference between "try another network"
    /// and "that is not the machine the code came from".
    private enum Attempt: Sendable {
        case connected(Connection)
        case failed(Endpoint, any Error)
    }

    public struct Connection: Sendable {
        public let transport: SSHTransport
        /// The endpoint that won. Worth persisting: it is nearly always still
        /// right next time, and trying it alone beats racing again.
        public let endpoint: Endpoint
    }

    /// Races every endpoint and keeps the first that authenticates.
    ///
    /// **Returns the moment one succeeds, and does not wait for the rest.**
    /// That is the whole point, and it needs saying because a task group cannot
    /// deliver it: leaving the group's scope awaits every child, and
    /// `group.cancelAll()` cannot shorten a losing attempt —
    /// `SSHClient.connect` does not observe task cancellation, so a dead
    /// address still costs its full TCP timeout. Waiting for that is exactly
    /// the cost the race exists to avoid.
    ///
    /// So the group runs in a detached task that outlives this call. It keeps
    /// draining after the winner is handed back, and **closes** any connection
    /// that finishes late — `SSHClient` has no deinit that does it, and an
    /// abandoned session stays open on the host. The drain ends on its own once
    /// every dial has finished.
    ///
    /// - Parameters:
    ///   - hostKey: OpenSSH `<algorithm> <base64>`, from the pairing QR or the
    ///     stored peer. Not trust-on-first-use: a mismatch is an error on the
    ///     very first connection, not a pin.
    public static func connect(
        endpoints: [Endpoint],
        username: String,
        hostKey: String,
        privateKey: SSHKeyPair,
        herdrPath: String = "herdr",
        session: String? = nil
    ) async throws -> Connection {
        guard !endpoints.isEmpty else {
            throw TransportError.connectionFailed("no endpoint to try")
        }

        return try await withCheckedThrowingContinuation { continuation in
            // Resumed exactly once, from whichever of the two paths gets there
            // first: a winner, or the drain running out of candidates.
            let done = LockedBox(false)
            let finish: @Sendable (Result<Connection, any Error>) -> Bool = { result in
                let already = done.withLock { was -> Bool in
                    defer { was = true }
                    return was
                }
                guard !already else { return false }
                continuation.resume(with: result)
                return true
            }

            Task.detached {
                await withTaskGroup(of: Attempt.self) { group in
                    for endpoint in endpoints {
                        group.addTask {
                            await attempt(
                                endpoint: endpoint,
                                username: username,
                                hostKey: hostKey,
                                privateKey: privateKey,
                                herdrPath: herdrPath,
                                session: session
                            )
                        }
                    }

                    var failures: [(Endpoint, any Error)] = []
                    for await result in group {
                        switch result {
                        case .failed(let endpoint, let error):
                            failures.append((endpoint, error))
                        case .connected(let connection):
                            if finish(.success(connection)) {
                                group.cancelAll()
                            } else {
                                await connection.transport.disconnect()
                            }
                        }
                    }
                    _ = finish(.failure(failure(from: failures, endpoints: endpoints)))
                }
            }
        }
    }

    /// Explains a race in which nothing won.
    ///
    /// A host key mismatch is promoted over everything else, because it is the
    /// only outcome here that is not about the network. A machine answered, and
    /// it was not the one the pairing code describes — either the code is for a
    /// different machine, or something is standing in for it. Reporting that as
    /// "no address answered" sends the user to check their Wi-Fi.
    private static func failure(
        from failures: [(Endpoint, any Error)],
        endpoints: [Endpoint]
    ) -> any Error {
        for (_, error) in failures {
            if case TransportError.hostKeyMismatch = error { return error }
        }
        return TransportError.connectionFailed(
            "none of \(endpoints.count) address(es) could be reached: "
            + endpoints.map(\.description).joined(separator: ", ")
        )
    }

    /// One endpoint. The race only cares which one worked, but *why* the others
    /// did not is what the message is built from when none did.
    private static func attempt(
        endpoint: Endpoint,
        username: String,
        hostKey: String,
        privateKey: SSHKeyPair,
        herdrPath: String,
        session: String?
    ) async -> Attempt {
        let transport = SSHTransport(
            host: SSHHost(username: username, hostname: endpoint.host, port: endpoint.port),
            privateKey: privateKey.privateKey,
            hostKeys: .expect(hostKey),
            herdrPath: herdrPath,
            session: session
        )
        do {
            // The handshake alone, with no command run over it. It already
            // proves everything "this endpoint works" can mean — TCP, the host
            // key, key exchange, authentication — and it proves it without
            // depending on what the host's shell prints on startup.
            try await transport.connect()
            return .connected(Connection(transport: transport, endpoint: endpoint))
        } catch {
            await transport.disconnect()
            return .failed(endpoint, error)
        }
    }
}
