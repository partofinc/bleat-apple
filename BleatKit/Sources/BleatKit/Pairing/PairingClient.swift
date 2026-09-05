import Foundation

/// The whole of the phone's side of pairing, from a scanned string to a stored
/// peer.
///
/// Split out from the UI so it can be driven from the console tool as well —
/// `bleat redeem` is the same code path a phone takes, which is how this gets
/// exercised end to end against a real `bleat pair` without an iPhone in hand.
public struct PairingClient: Sendable {
    private let peers: PeerStore
    private let deviceKey: SSHKeyPair

    /// - Parameter deviceKey: The phone's durable key. On iOS this comes from
    ///   the Keychain and is generated on first launch; the caller owns where
    ///   it lives, because the console tool keeps its keys in a file.
    public init(peers: PeerStore, deviceKey: SSHKeyPair) {
        self.peers = peers
        self.deviceKey = deviceKey
    }

    /// Scans, connects, swaps keys, and records the peer.
    ///
    /// - Parameter code: The QR's contents — a `bleat://pair?d=…` URL.
    /// - Returns: The stored record. For a machine that was already paired this
    ///   is the **merge**, carrying the endpoints it was reachable at before as
    ///   well as the one just scanned.
    public func pair(withCode code: String) async throws -> PairedPeer {
        let payload = try PairingPayload(urlString: code)
        let enrollmentKey = try payload.enrollmentKey()

        let connection: PeerConnector.Connection
        do {
            connection = try await PeerConnector.connect(
                endpoints: payload.endpoints,
                username: payload.username,
                hostKey: payload.hostKey,
                privateKey: enrollmentKey
            )
        } catch TransportError.hostKeyMismatch(let expected, let actual) {
            // The transport calls this a *changed* key, which is what it means
            // when the expectation came from a pin built by trust-on-first-use.
            // Here it came from the code in the user's hand and nothing has ever
            // been trusted, so the honest report is that the machine answering
            // is not the one the code describes.
            throw PairingError.hostKeyMismatch(expected: expected, actual: actual)
        }

        // Held so the second connection can be closed on every path out.
        let deviceSession = LockedBox<SSHTransport?>(nil)
        let redemption: Enrollment.Redemption
        do {
            redemption = try await Enrollment.redeem(
                deviceKey: deviceKey,
                enrollmentKey: enrollmentKey,
                on: connection.transport
            ) {
                // The same endpoint, not a fresh race: the question is whether
                // *this* host accepts the new key, and racing could answer it
                // about a different address.
                let proof = try await PeerConnector.connect(
                    endpoints: [connection.endpoint],
                    username: payload.username,
                    hostKey: payload.hostKey,
                    privateKey: deviceKey
                )
                deviceSession.withLock { $0 = proof.transport }
                return proof.transport
            }
        } catch {
            // `defer` cannot await, and leaving either session open would hold
            // a channel on the host — visible in `who`, and one of them
            // authenticated by a key that is about to expire.
            await close(connection.transport, deviceSession.current)
            throw error
        }
        await close(connection.transport, deviceSession.current)

        var peer = PairedPeer(payload: payload)
        peer.herdrPath = redemption.herdrPath
        peer.lastGoodEndpoint = connection.endpoint
        // Merging is `PeerStore.save`'s job, so re-pairing the same machine
        // from a second network keeps the addresses it already had.
        //
        // By this point the pairing cannot be undone: the enrollment key is
        // gone from the host, so a failure to write the record locally is not
        // something rescanning fixes. `PeerStore.all()` tolerates a *missing*
        // file but not an undecodable one, which is the realistic way this
        // fails — and the user needs to be told the host half succeeded.
        do {
            return try peers.save(peer)
        } catch {
            throw PairingError.peerNotRecorded(String(describing: error))
        }
    }

    /// Both sessions, on every path out. `defer` cannot await, so this is
    /// called explicitly rather than scoped.
    private func close(_ enrollment: SSHTransport, _ device: SSHTransport?) async {
        await enrollment.disconnect()
        if let device { await device.disconnect() }
    }
}
