import Foundation
import Testing
@testable import BleatKit

@Suite("Paired peer")
struct PairedPeerTests {

    private let fingerprint = "SHA256:5kgLcSfLx2/OaEHRcfc7PhrQ2uLNlTc8aL19AfjYn78"

    private func peer(
        endpoints: [Endpoint],
        lastGood: Endpoint? = nil,
        name: String = "rawillk.air",
        user: String = "ravil",
        herdr: String = "/opt/homebrew/bin/herdr"
    ) -> PairedPeer {
        PairedPeer(
            hostKeyFingerprint: fingerprint, name: name, username: user,
            endpoints: endpoints, herdrPath: herdr, lastGoodEndpoint: lastGood
        )
    }

    /// The whole reason identity is the host key: pairing the same machine
    /// again from a different network must add a way in, not a second peer.
    @Test("pairing again over a new network adds an endpoint, not a peer")
    func mergeAddsEndpoints() {
        let lan = peer(endpoints: [Endpoint(host: "rawillkair.local"), Endpoint(host: "192.168.11.54")])
        let overTailscale = peer(endpoints: [Endpoint(host: "100.101.102.103")])
        let merged = lan.merging(overTailscale)

        #expect(merged.id == lan.id)
        #expect(merged.endpoints.map(\.host) == ["rawillkair.local", "192.168.11.54", "100.101.102.103"])
    }

    /// Pairing over Tailscale must not cost the peer its LAN addresses — those
    /// are the fast path when the phone comes home.
    @Test("merging never drops an existing endpoint")
    func mergeKeepsOldEndpoints() {
        let lan = peer(endpoints: [Endpoint(host: "rawillkair.local")])
        let merged = lan.merging(peer(endpoints: [Endpoint(host: "100.101.102.103")]))
        #expect(merged.endpoints.contains(Endpoint(host: "rawillkair.local")))
    }

    @Test("re-pairing from the same place does not duplicate endpoints")
    func mergeIsIdempotent() {
        let original = peer(endpoints: [Endpoint(host: "rawillkair.local"), Endpoint(host: "192.168.11.54")])
        let merged = original.merging(original)
        #expect(merged.endpoints == original.endpoints)
    }

    @Test("mutable details take the newer value, since the tool just read them off the host")
    func mergeRefreshesDetails() {
        let old = peer(endpoints: [Endpoint(host: "a")], name: "old", user: "olduser", herdr: "/old/herdr")
        let new = peer(endpoints: [Endpoint(host: "a")], name: "new", user: "newuser", herdr: "/new/herdr")
        let merged = old.merging(new)
        #expect(merged.name == "new")
        #expect(merged.username == "newuser")
        #expect(merged.herdrPath == "/new/herdr")
    }

    @Test("a peer built from a payload carries its endpoints and identity")
    func fromPayload() {
        let payload = PairingPayload(
            name: "rawillk.air", username: "ravil",
            endpoints: [Endpoint(host: "rawillkair.local"), Endpoint(host: "100.101.102.103")],
            enrollmentSeed: Data(repeating: 3, count: 32),
            hostKeyFingerprint: fingerprint, herdrPath: "/opt/homebrew/bin/herdr"
        )
        let built = PairedPeer(payload: payload)
        #expect(built.hostKeyFingerprint == fingerprint)
        #expect(built.endpoints.count == 2)
        #expect(built.lastGoodEndpoint == nil)
    }
}

@Suite("Endpoint selection")
struct EndpointSelectionTests {

    private func peer(_ hosts: [String], lastGood: String? = nil) -> PairedPeer {
        PairedPeer(
            hostKeyFingerprint: "SHA256:x", name: "n", username: "u",
            endpoints: hosts.map { Endpoint(host: $0) }, herdrPath: "/bin/herdr",
            lastGoodEndpoint: lastGood.map { Endpoint(host: $0) }
        )
    }

    /// The rule that saves most of the latency. `.local` cannot resolve and
    /// RFC1918 cannot route once the phone is on cellular, so they are dropped
    /// rather than ordered last — trying them only spends the timeout.
    @Test("off the local link, LAN endpoints are dropped rather than deprioritised")
    func offLinkDropsLAN() {
        let p = peer(["rawillkair.local", "192.168.11.54", "100.101.102.103", "herdr.dev"])
        #expect(p.endpointsToTry(onLocalLink: false).map(\.host) == ["100.101.102.103", "herdr.dev"])
    }

    @Test("on the local link, everything is a candidate")
    func onLinkKeepsAll() {
        let p = peer(["rawillkair.local", "192.168.11.54", "100.101.102.103"])
        #expect(p.endpointsToTry(onLocalLink: true).count == 3)
    }

    @Test("last-known-good is tried first and not repeated")
    func lastGoodLeads() {
        let p = peer(["rawillkair.local", "192.168.11.54", "100.101.102.103"], lastGood: "100.101.102.103")
        let order = p.endpointsToTry(onLocalLink: true).map(\.host)
        #expect(order == ["100.101.102.103", "rawillkair.local", "192.168.11.54"])
    }

    /// A remembered LAN address is still unreachable on cellular; being the
    /// last good one does not exempt it from the filter.
    @Test("a last-known-good LAN endpoint is still dropped off-link")
    func lastGoodStillFiltered() {
        let p = peer(["rawillkair.local", "100.101.102.103"], lastGood: "rawillkair.local")
        #expect(p.endpointsToTry(onLocalLink: false).map(\.host) == ["100.101.102.103"])
    }

    @Test("a peer with only LAN endpoints yields nothing off-link, rather than a doomed attempt")
    func noneUsableOffLink() {
        let p = peer(["rawillkair.local", "192.168.11.54"])
        #expect(p.endpointsToTry(onLocalLink: false).isEmpty)
    }
}
