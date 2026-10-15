import Foundation

/// The whole of the phone's side of pairing, from a scanned string to a stored
/// peer.
///
/// Split out from the UI so it can be driven from the console tool as well —
/// `bleat redeem` is the same code path a phone takes, which is how this gets
/// exercised end to end against a real `bleat pair` without an iPhone in hand.
public struct PairingClient: Sendable {
    private let peers: PeerRegistry
    private let deviceKey: SSHKeyPair

    /// - Parameter deviceKey: The phone's durable key. On iOS this comes from
    ///   the Keychain and is generated on first launch; the caller owns where
    ///   it lives, because the console tool keeps its keys in a file.
    public init(peers: PeerRegistry, deviceKey: SSHKeyPair) {
        self.peers = peers
        self.deviceKey = deviceKey
    }

    /// Scans, connects, swaps keys, and records the peer.
    ///
    /// - Parameter code: The QR's contents — a `bleat://pair?d=…` URL.
    /// - Returns: The stored record. For a machine that was already paired this
    ///   is the **merge**, carrying the endpoints it was reachable at before as
    ///   well as the one just scanned.
    ///
    /// `@concurrent` because the caller is the pairing screen, and this
    /// generates a key and drives two SSH handshakes.
    @concurrent
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
        var peer = PairedPeer(payload: payload)
        peer.herdrPath = redemption.herdrPath
        peer.lastGoodEndpoint = connection.endpoint
        // Kept so unpairing can name the line it leaves behind if it cannot
        // remove it. `Enrollment` has always returned this; it used to be
        // dropped here, which left the phone unable to say which of the host's
        // keys was its own.
        peer.deviceMarker = redemption.deviceMarker
        // Merging is `PeerRegistry.save`'s job, so re-pairing the same machine
        // from a second network keeps the addresses it already had.
        //
        // By this point the pairing cannot be undone: the enrollment key is
        // gone from the host, so a failure to write the record locally is not
        // something rescanning fixes. `PeerRegistry.all()` tolerates a *missing*
        // file but not an undecodable one, which is the realistic way this
        // fails — and the user needs to be told the host half succeeded.
        //
        // Saved **before** the host is asked what it is, and that order is
        // the point: the probe is a shell command on someone else's machine,
        // and one that stalled here would leave a key on the host and no
        // record of it on the phone.
        let saved: PairedPeer
        do {
            saved = try peers.save(peer)
        } catch {
            await close(connection.transport, deviceSession.current)
            throw PairingError.peerNotRecorded(String(describing: error))
        }

        // What the host is, over the device session while it is still open,
        // so the new host arrives in the list with its mark and system rather
        // than waiting for the first time someone opens it. Best effort, and
        // bounded: closing the sessions is what ends a probe that overran.
        let info = await hostInfo(over: deviceSession.current, herdrPath: redemption.herdrPath)
        await close(connection.transport, deviceSession.current)
        guard let info,
              (try? peers.recordHostInfo(info, forHostKey: saved.hostKey)) == true,
              let recorded = try? peers.peer(hostKey: saved.hostKey)
        else { return saved }
        return recorded
    }

    /// How long pairing waits for the host to say what it is. The probe
    /// without its processor sample takes a few dozen milliseconds; this is
    /// for a host whose `$HOME` sits on a mount that has stopped answering.
    static let hostInfoDeadline: Duration = .seconds(5)

    /// Asks the host what it is, without the second-long processor sample.
    /// Nil when there is no session or nothing came back.
    ///
    /// **Raced against a deadline rather than awaited**, because nothing
    /// shorter would end it: `run(shell:)` has no timeout, and a task group
    /// waits for every child before it returns. Whichever finishes first is
    /// the answer; the caller then closes the session, which fails the
    /// command if it is still running.
    private func hostInfo(over session: SSHTransport?, herdrPath: String) async -> HostInfo? {
        guard let session else { return nil }
        let command = HostStatusProbe.command(herdrPath: herdrPath, sampling: false)
        return await Self.first(within: Self.hostInfoDeadline) {
            guard let output = try? await session.run(shell: command) else { return nil }
            let info = HostStatusProbe.status(fromOutput: output).info
            return info.isEmpty ? nil : info
        }
    }

    /// `work`'s answer, or nil once `limit` has passed, without waiting for
    /// `work` to notice. Internal for a test.
    static func first<T: Sendable>(
        within limit: Duration,
        _ work: @escaping @Sendable () async -> T?
    ) async -> T? {
        let (answers, continuation) = AsyncStream.makeStream(of: T?.self)
        let worker = Task {
            continuation.yield(await work())
            continuation.finish()
        }
        let timer = Task {
            try? await Task.sleep(for: limit)
            continuation.yield(nil)
            continuation.finish()
        }
        var answer: T?
        for await first in answers {
            answer = first
            break
        }
        timer.cancel()
        worker.cancel()
        return answer
    }

    /// Both sessions, on every path out. `defer` cannot await, so this is
    /// called explicitly rather than scoped.
    private func close(_ enrollment: SSHTransport, _ device: SSHTransport?) async {
        await enrollment.disconnect()
        if let device { await device.disconnect() }
    }
}
