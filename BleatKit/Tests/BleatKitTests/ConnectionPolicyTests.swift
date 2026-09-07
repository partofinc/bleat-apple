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
            cachedHostKey: "ssh-ed25519 AAAAKEY", cachedLink: .localLink,
            for: peer(), link: .localLink
        ))
    }

    @Test("a different host is a different connection")
    func differentHost() {
        #expect(!ConnectionPolicy.canReuse(
            cachedHostKey: "ssh-ed25519 AAAAOTHER", cachedLink: .localLink,
            for: peer(), link: .localLink
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
            cachedHostKey: "ssh-ed25519 AAAAKEY", cachedLink: .localLink,
            for: peer(), link: .offLink
        ))
        #expect(!ConnectionPolicy.canReuse(
            cachedHostKey: "ssh-ed25519 AAAAKEY", cachedLink: .offLink,
            for: peer(), link: .localLink
        ))
    }

    /// A tunnel coming up is a network change too, and this is the one that
    /// would otherwise be silent. It widens the candidate list — a private
    /// address is dropped without one and raced with one — so a connection made
    /// before the VPN connected was raced over a strictly smaller set. Reusing
    /// it would keep the phone on that smaller set for as long as the screen
    /// stays open, which is precisely the shape of bug the link half of this
    /// key was added to fix.
    @Test("a tunnel coming up or going down invalidates the cached connection")
    func tunnelChanged() {
        let cellular = LinkState.offLink
        let tunnelled = LinkState(onLocalLink: false, tunnelActive: true)
        #expect(!ConnectionPolicy.canReuse(
            cachedHostKey: "ssh-ed25519 AAAAKEY", cachedLink: cellular,
            for: peer(), link: tunnelled
        ))
        #expect(!ConnectionPolicy.canReuse(
            cachedHostKey: "ssh-ed25519 AAAAKEY", cachedLink: tunnelled,
            for: peer(), link: cellular
        ))
        #expect(ConnectionPolicy.canReuse(
            cachedHostKey: "ssh-ed25519 AAAAKEY", cachedLink: tunnelled,
            for: peer(), link: tunnelled
        ))
    }

    /// …but **only off the link**, and this is the other half of getting that
    /// key right. On Wi-Fi every endpoint is a candidate whatever the tunnel is
    /// doing, so a tunnel change cannot alter the raced list — and comparing it
    /// would throw away a working connection for nothing. An on-demand VPN
    /// profile connecting and dropping while the app sits on Wi-Fi would tear
    /// down the live SSH session and re-handshake on the next request, over and
    /// over, for a list that did not change.
    @Test("a tunnel changing on Wi-Fi does not invalidate anything")
    func tunnelChangeOnTheLinkIsIrrelevant() {
        let plain = LinkState.localLink
        let withTunnel = LinkState(onLocalLink: true, tunnelActive: true)
        #expect(ConnectionPolicy.canReuse(
            cachedHostKey: "ssh-ed25519 AAAAKEY", cachedLink: plain,
            for: peer(), link: withTunnel
        ))
        #expect(ConnectionPolicy.canReuse(
            cachedHostKey: "ssh-ed25519 AAAAKEY", cachedLink: withTunnel,
            for: peer(), link: plain
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
