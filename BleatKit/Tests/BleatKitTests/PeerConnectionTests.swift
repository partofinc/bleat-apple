import Foundation
import Testing
@testable import BleatKit

@Suite("Connecting to a paired peer")
struct PeerConnectionTests {

    private func peer(_ endpoints: [String]) -> PairedPeer {
        PairedPeer(
            hostKey: "ssh-ed25519 AAAAKEY",
            name: "Mac",
            username: "ravil",
            endpoints: endpoints.compactMap { Endpoint(string: $0) },
            herdrPath: "/opt/homebrew/bin/herdr"
        )
    }

    /// Off the local link there is nothing to try, and saying "nothing
    /// answered" would be a lie: the addresses were not tried, they were ruled
    /// out. The remedy is a different network — or an overlay endpoint — rather
    /// than a host that needs starting.
    @Test("a LAN-only peer on cellular is refused before anything is dialled")
    func lanOnlyPeerOffLink() async {
        let lanOnly = peer(["mac.local", "192.168.1.20"])
        #expect(lanOnly.endpointsToTry(from: .offLink).isEmpty)

        await #expect(throws: TransportError.self) {
            try await PeerConnection.connect(
                to: lanOnly, deviceKey: SSHKeyPair(), link: .offLink
            )
        }
    }

    /// The same peer on Wi-Fi has both addresses to race.
    @Test("on the local link the LAN addresses are candidates again")
    func lanOnlyPeerOnLink() {
        #expect(peer(["mac.local", "192.168.1.20"]).endpointsToTry(from: .localLink).count == 2)
    }

    /// An overlay address routes from anywhere, so a peer that has one is not
    /// stranded by leaving the house — and the LAN entries are still dropped,
    /// because trying them off-link only spends the timeout.
    @Test("an overlay address survives leaving the local network")
    func overlaySurvives() {
        let mixed = peer(["mac.local", "192.168.1.20", "mac.tail1234.ts.net"])
        let offLink = mixed.endpointsToTry(from: .offLink)
        #expect(offLink.map(\.description) == ["mac.tail1234.ts.net"])
    }

    /// A peer with no address at all is a different message again: nothing to
    /// try anywhere, rather than nothing to try from here.
    @Test("a peer with no endpoints says so rather than reporting a failed dial")
    func noEndpoints() async {
        await #expect(throws: TransportError.self) {
            try await PeerConnection.connect(
                to: peer([]), deviceKey: SSHKeyPair(), link: .localLink
            )
        }
    }

    /// **The case this whole change exists for.** The phone is on cellular with
    /// a zero-trust client up, and the host is an ordinary Mac on a private
    /// network — no Tailscale, nothing to discover, no address of its own that
    /// the overlay hands out. The only endpoint that can work is the plain
    /// `192.168.x` one, and before this it was dropped before it was dialled.
    ///
    /// The `.local` name stays dropped, because multicast does not travel.
    @Test("a tunnel brings the private address back without bringing back mDNS")
    func tunnelRestoresPrivateAddresses() {
        let lanOnly = peer(["mac.local", "192.168.1.20"])
        let tunnelled = LinkState(onLocalLink: false, tunnelActive: true)
        #expect(lanOnly.endpointsToTry(from: tunnelled).map(\.description) == ["192.168.1.20"])
    }

    /// A tunnel does not invent an endpoint. A peer whose only address is an
    /// mDNS name is still refused before anything is dialled, and the message
    /// is the ruled-out one rather than "nothing answered".
    @Test("a tunnel cannot rescue a peer that only has an mDNS name")
    func tunnelDoesNotRescueMDNSOnlyPeer() async {
        let mdnsOnly = peer(["mac.local"])
        let tunnelled = LinkState(onLocalLink: false, tunnelActive: true)
        #expect(mdnsOnly.endpointsToTry(from: tunnelled).isEmpty)

        await #expect(throws: TransportError.self) {
            try await PeerConnection.connect(
                to: mdnsOnly, deviceKey: SSHKeyPair(), link: tunnelled
            )
        }
    }
}
