import Citadel
import Foundation
import NIOCore
import NIOSSH

/// Validates a server's host key, failing hard on any disagreement.
///
/// Where the expected key comes from is `HostKeyPolicy`'s business: a file of
/// pins built by trust-on-first-use, or a key handed over out of band by a
/// pairing QR. Both end up comparing the same string — the OpenSSH
/// `<algorithm> <base64>` form — so there is one notion of "same host key" in
/// the package.
final class PinningHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let host: String
    private let policy: HostKeyPolicy
    /// Set when validation fails, so the transport can report why rather than
    /// surfacing NIO's opaque authentication error.
    private let failure = LockedBox<(any Error)?>(nil)

    init(host: String, policy: HostKeyPolicy) {
        self.host = host
        self.policy = policy
    }

    var recordedFailure: (any Error)? { failure.current }

    /// Clears the last failure so a fresh dial reports its own outcome.
    func clearRecordedFailure() { failure.withLock { $0 = nil } }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        // "algorithm-id base64-key" — the same shape OpenSSH pins.
        let presented = String(openSSHPublicKey: hostKey)

        do {
            switch policy {
            case .expect(let expected):
                guard expected == presented else {
                    throw TransportError.hostKeyMismatch(expected: expected, actual: presented)
                }
            case .knownHosts(let store):
                if let pinned = try store.pinnedKey(for: host) {
                    guard pinned == presented else {
                        throw TransportError.hostKeyMismatch(expected: pinned, actual: presented)
                    }
                } else {
                    try store.pin(presented, for: host)
                }
            }
            validationCompletePromise.succeed(())
        } catch {
            failure.withLock { $0 = error }
            validationCompletePromise.fail(error)
        }
    }
}
