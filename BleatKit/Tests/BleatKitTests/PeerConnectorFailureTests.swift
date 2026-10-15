import Foundation
import Testing
@testable import BleatKit

/// What the user is told when a race finishes with nothing.
///
/// This message is the only explanation they get, and it reaches every screen.
/// Getting it wrong sends them to fix something that is not broken.
@Suite("Explaining a race nothing won")
struct PeerConnectorFailureTests {

    private func message(
        _ endpoints: [Endpoint],
        _ errors: [any Error] = [],
        everyCandidateNeedsATunnel: Bool = true
    ) -> String {
        let failures = zip(endpoints, errors).map { ($0, $1) }
        let error = PeerConnector.failure(
            from: Array(failures), endpoints: endpoints,
            everyCandidateNeedsATunnel: everyCandidateNeedsATunnel
        )
        return String(describing: error)
    }

    /// Exactly what `PeerConnection` computes before handing the verdict down.
    /// Restated here rather than reached through `PeerConnection.connect`,
    /// which would dial — and no test in this package touches the network.
    private func verdict(_ endpoints: [Endpoint], from link: LinkState) -> Bool {
        endpoints.allSatisfy { $0.needsTunnel(from: link) }
    }

    /// On cellular against a Tailscale-only host, `endpointsToTry` has already
    /// dropped the `.local` name and the LAN addresses as unroutable — so
    /// everything left is a tunnel address, and the likeliest reason nothing
    /// answered is that the tunnel is down on this device. "No address could be
    /// reached" sends the user to check a network that is working perfectly.
    @Test("all-overlay endpoints name the VPN rather than the network")
    func overlayOnlyNamesTheVPN() {
        let text = message([
            Endpoint(host: "100.111.222.33", port: 22),
            Endpoint(host: "somemac.tailexample.ts.net", port: 22),
        ])
        #expect(text.contains("VPN"))
        #expect(text.contains("100.111.222.33"))
    }

    /// A LAN address in the list means the phone is on Wi-Fi and the ordinary
    /// explanation applies: the host is off, asleep, or somewhere else.
    /// Blaming a VPN there would be a guess, and a misleading one.
    @Test("a mixed list gets the ordinary message")
    func mixedGetsTheOrdinaryMessage() {
        let endpoints = [
            Endpoint(host: "somemac.local", port: 22),
            Endpoint(host: "100.111.222.33", port: 22),
        ]
        #expect(!verdict(endpoints, from: .localLink))
        let text = message(endpoints, everyCandidateNeedsATunnel: false)
        #expect(text.contains("none of 2"))
        #expect(!text.contains("VPN"))
    }

    /// **The case a plain "are we off-link" flag lost.** A peer paired over the
    /// tailnet has one endpoint, a mesh address. The phone is on Wi-Fi with
    /// Tailscale switched off, so nothing answers — and the remedy is the
    /// tunnel, on Wi-Fi as much as on cellular. An earlier version suppressed
    /// this message whenever `onLocalLink`, and sent the user to check a Wi-Fi
    /// network that was working perfectly.
    @Test("a mesh-only peer names the VPN even on Wi-Fi")
    func meshOnlyPeerOnWiFiStillNamesTheVPN() {
        let endpoints = [Endpoint(host: "somemac.tailexample.ts.net", port: 22)]
        #expect(verdict(endpoints, from: .localLink))
        #expect(message(endpoints, everyCandidateNeedsATunnel: true).contains("VPN"))
    }

    /// The mirror of it. On Wi-Fi a private address is simply the network the
    /// phone is standing on, so a failure there means the host is asleep —
    /// naming a VPN would send the user to set up something they do not need.
    /// Off the link the same address is a candidate *only* because a tunnel was
    /// detected, so there the advice is right.
    @Test("a private address blames the VPN off the link and never on it")
    func privateAddressDependsOnWhereThePhoneIs() {
        let endpoints = [Endpoint(host: "192.168.50.54", port: 22)]
        #expect(!verdict(endpoints, from: .localLink))
        #expect(verdict(endpoints, from: LinkState(onLocalLink: false, tunnelActive: true)))
    }

    /// **The flag is the whole safety of that message**, and this is the case
    /// it protects. Pairing calls the connector a second time with a
    /// deliberately narrowed list — one endpoint, the one that just carried the
    /// enrollment handshake — to ask whether this host accepts the new device
    /// key. Every candidate is trivially an overlay address there, but the
    /// tunnel demonstrably just worked, so telling the user to check their VPN
    /// would be false. And it lands at the worst moment in the flow: the
    /// enrollment key may already be spent, so the user cannot simply rescan.
    @Test("a narrowed list is not read as a VPN problem")
    func narrowedListIsNotAVPNProblem() {
        let text = message(
            [Endpoint(host: "100.111.222.33", port: 22)],
            everyCandidateNeedsATunnel: false
        )
        #expect(!text.contains("VPN"))
        #expect(text.contains("none of 1"))
    }

    /// It is its own error case rather than a `connectionFailed` with different
    /// words, because callers classify on the case. `PairingModel` treats a
    /// plain `connectionFailed` as possibly iOS's local network permission and
    /// waits a minute for an answer — which cannot be the cause when no local
    /// address was dialled at all.
    @Test("the VPN failure is a distinct case, not a different sentence")
    func vpnFailureIsItsOwnCase() {
        let endpoints = [Endpoint(host: "100.111.222.33", port: 22)]
        let error = PeerConnector.failure(
            from: [], endpoints: endpoints, everyCandidateNeedsATunnel: true
        )
        guard case TransportError.overlayUnreachable = error else {
            Issue.record("expected overlayUnreachable, got \(error)")
            return
        }
    }

    /// Identity outranks the network. A machine answered and was not the one
    /// the record describes, which is not about addresses at all.
    @Test("a host key mismatch is still promoted over everything")
    func mismatchWins() {
        let endpoint = Endpoint(host: "100.111.222.33", port: 22)
        let error = PeerConnector.failure(
            from: [(endpoint, TransportError.hostKeyMismatch(expected: "a", actual: "b"))],
            endpoints: [endpoint]
        )
        guard case TransportError.hostKeyMismatch = error else {
            Issue.record("expected a host key mismatch, got \(error)")
            return
        }
    }

    /// A host that refused the key was *reached*, so the VPN is demonstrably
    /// up and saying otherwise would be false.
    @Test("a refused key is promoted over the VPN message")
    func authenticationWins() {
        let endpoint = Endpoint(host: "100.111.222.33", port: 22)
        let error = PeerConnector.failure(
            from: [(endpoint, TransportError.authenticationFailed("no method succeeded"))],
            endpoints: [endpoint]
        )
        guard case TransportError.authenticationFailed = error else {
            Issue.record("expected an authentication failure, got \(error)")
            return
        }
    }
}
