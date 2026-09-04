import Citadel
import Foundation
import NIOCore
import NIOSSH

/// Validates a server's host key against `KnownHostsStore`, pinning on first
/// sight and failing hard on any change.
final class PinningHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let host: String
    private let store: KnownHostsStore
    /// Set when validation fails, so the transport can report why rather than
    /// surfacing NIO's opaque authentication error.
    private let failure = LockedBox<(any Error)?>(nil)

    init(host: String, store: KnownHostsStore) {
        self.host = host
        self.store = store
    }

    var recordedFailure: (any Error)? { failure.current }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        // "algorithm-id base64-key" — the same shape OpenSSH pins.
        let fingerprint = String(openSSHPublicKey: hostKey)

        do {
            if let pinned = try store.pinnedKey(for: host) {
                guard pinned == fingerprint else {
                    let error = TransportError.hostKeyMismatch(expected: pinned, actual: fingerprint)
                    failure.withLock { $0 = error }
                    validationCompletePromise.fail(error)
                    return
                }
            } else {
                try store.pin(fingerprint, for: host)
            }
            validationCompletePromise.succeed(())
        } catch {
            failure.withLock { $0 = error }
            validationCompletePromise.fail(error)
        }
    }
}
