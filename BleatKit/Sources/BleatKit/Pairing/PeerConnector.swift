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
    /// Each attempt is bounded by NIO's own connect timeout rather than by a
    /// deadline here, which would only look like a bound: `SSHClient.connect`
    /// does not observe task cancellation, so a timeout could stop *waiting*
    /// without stopping the dial. The race is what makes this fast in practice
    /// — one slow address costs nothing as long as another answers.
    ///
    /// - Parameters:
    ///   - hostKey: OpenSSH `<algorithm> <base64>`, from the pairing QR or the
    ///     stored peer. Not trust-on-first-use: a mismatch is an error on the
    ///     very first connection, not a pin.
    ///   - probe: Run on each candidate to prove the channel works. The
    ///     handshake alone is not proof — the transport connects lazily, so
    ///     without running something there is nothing to race.
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

        return try await withThrowingTaskGroup(of: Attempt.self) { group in
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

            var winner: Connection?
            var failures: [(Endpoint, any Error)] = []
            for try await result in group {
                switch result {
                case .failed(let endpoint, let error):
                    failures.append((endpoint, error))
                case .connected(let connection):
                    if winner == nil {
                        winner = connection
                        group.cancelAll()
                    } else {
                        // A late arrival on a second address is a real, open
                        // SSH session on the host. Dropping the reference would
                        // leave it there — `SSHClient` has no deinit that
                        // closes it — so the loser is closed, not forgotten.
                        await connection.transport.disconnect()
                    }
                }
            }

            guard let winner else { throw failure(from: failures, endpoints: endpoints) }
            return winner
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
            // Cheap, present everywhere, and it proves the whole path: TCP,
            // the host key, the key exchange, authentication, and that an exec
            // channel actually runs a command.
            guard try await transport.run(shell: "printf ok") == "ok" else {
                await transport.disconnect()
                return .failed(endpoint, TransportError.connectionFailed("no answer from the shell"))
            }
            return .connected(Connection(transport: transport, endpoint: endpoint))
        } catch {
            await transport.disconnect()
            return .failed(endpoint, error)
        }
    }
}
