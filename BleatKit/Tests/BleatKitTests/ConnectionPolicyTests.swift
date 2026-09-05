import Foundation
import Testing
@testable import BleatKit

@Suite("Reusing and discarding a connection")
struct ConnectionPolicyTests {

    private func peer(_ key: String = "ssh-ed25519 AAAAKEY") -> PairedPeer {
        PairedPeer(
            hostKey: key,
            name: "Mac",
            username: "ravil",
            endpoints: [Endpoint(host: "mac.local")],
            herdrPath: "/opt/homebrew/bin/herdr"
        )
    }

    @Test("the same host on the same kind of network reuses the connection")
    func reusesWhenNothingChanged() {
        #expect(ConnectionPolicy.canReuse(
            cachedHostKey: "ssh-ed25519 AAAAKEY", cachedOnLocalLink: true,
            for: peer(), onLocalLink: true
        ))
    }

    @Test("a different host is a different connection")
    func differentHost() {
        #expect(!ConnectionPolicy.canReuse(
            cachedHostKey: "ssh-ed25519 AAAAOTHER", cachedOnLocalLink: true,
            for: peer(), onLocalLink: true
        ))
    }

    /// The half that was missing. A connection is raced once and then pinned to
    /// the address that won, so one made on Wi-Fi against a `.local` name can
    /// only fail once the phone is on cellular — and the peer's overlay
    /// address, which would have worked, never gets a turn because the cache
    /// answered first.
    @Test("leaving the local network invalidates a connection made on it")
    func networkChanged() {
        #expect(!ConnectionPolicy.canReuse(
            cachedHostKey: "ssh-ed25519 AAAAKEY", cachedOnLocalLink: true,
            for: peer(), onLocalLink: false
        ))
        #expect(!ConnectionPolicy.canReuse(
            cachedHostKey: "ssh-ed25519 AAAAKEY", cachedOnLocalLink: false,
            for: peer(), onLocalLink: true
        ))
    }

    @Test("a transport failure ends the connection")
    func transportErrorIsFatal() {
        #expect(ConnectionPolicy.isFatalToConnection(TransportError.channelClosed))
        #expect(ConnectionPolicy.isFatalToConnection(
            TransportError.connectionFailed("none of 2 address(es) could be reached")
        ))
    }

    /// The host was reached and said no. Reconnecting would cost a handshake
    /// per retry and hide the real problem behind a reconnection that always
    /// succeeds.
    @Test("a command the host refused does not")
    func herdrErrorIsNotFatal() {
        #expect(!ConnectionPolicy.isFatalToConnection(
            HerdrError(command: ["agent", "list"], exitCode: 1, stderr: "no such session")
        ))
        #expect(!ConnectionPolicy.isFatalToConnection(CancellationError()))
        #expect(!ConnectionPolicy.isFatalToConnection(
            ShellError(command: "true", exitCode: 1, stderr: "")
        ))
    }
}
