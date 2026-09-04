import Foundation
import Testing
@testable import BleatKit

@Suite("Paired peer")
struct PairedPeerTests {

    private let hostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBPdxsAyNEaNtfx47Futg4ERIBkkAsvtWfxnTeKq0jct"

    private func peer(
        endpoints: [Endpoint],
        lastGood: Endpoint? = nil,
        name: String = "rawillk.air",
        user: String = "ravil",
        herdr: String = "/opt/homebrew/bin/herdr"
    ) -> PairedPeer {
        PairedPeer(
            hostKey: hostKey, name: name, username: user,
            endpoints: endpoints, herdrPath: herdr, lastGoodEndpoint: lastGood
        )
    }

    /// The whole reason identity is the host key: pairing the same machine
    /// again from a different network must add a way in, not a second peer.
    @Test("pairing again over a new network adds an endpoint, not a peer")
    func mergeAddsEndpoints() throws {
        let lan = peer(endpoints: [Endpoint(host: "rawillkair.local"), Endpoint(host: "192.168.11.54")])
        let overTailscale = peer(endpoints: [Endpoint(host: "100.101.102.103")])
        let merged = try lan.merging(overTailscale)

        #expect(merged.id == lan.id)
        #expect(merged.endpoints.map(\.host) == ["rawillkair.local", "192.168.11.54", "100.101.102.103"])
    }

    /// Pairing over Tailscale must not cost the peer its LAN addresses — those
    /// are the fast path when the phone comes home.
    @Test("merging never drops an existing endpoint")
    func mergeKeepsOldEndpoints() throws {
        let lan = peer(endpoints: [Endpoint(host: "rawillkair.local")])
        let merged = try lan.merging(peer(endpoints: [Endpoint(host: "100.101.102.103")]))
        #expect(merged.endpoints.contains(Endpoint(host: "rawillkair.local")))
    }

    @Test("re-pairing from the same place does not duplicate endpoints")
    func mergeIsIdempotent() throws {
        let original = peer(endpoints: [Endpoint(host: "rawillkair.local"), Endpoint(host: "192.168.11.54")])
        let merged = try original.merging(original)
        #expect(merged.endpoints == original.endpoints)
    }

    @Test("mutable details take the newer value, since the tool just read them off the host")
    func mergeRefreshesDetails() throws {
        let old = peer(endpoints: [Endpoint(host: "a")], name: "old", user: "olduser", herdr: "/old/herdr")
        let new = peer(endpoints: [Endpoint(host: "a")], name: "new", user: "newuser", herdr: "/new/herdr")
        let merged = try old.merging(new)
        #expect(merged.name == "new")
        #expect(merged.username == "newuser")
        #expect(merged.herdrPath == "/new/herdr")
    }

    /// `merging` takes an argument built straight from a scanned QR, so a
    /// mismatch has to reach the user as a message. A `precondition` here
    /// would trap in release: scanning the wrong code would crash the app
    /// rather than say the host key does not match.
    @Test("merging across identities is a reportable error, not a trap")
    func mergeRejectsDifferentHostKey() {
        let mine = peer(endpoints: [Endpoint(host: "a")])
        let other = PairedPeer(
            hostKey: "ssh-ed25519 AAAAdifferent", name: "n", username: "u",
            endpoints: [Endpoint(host: "b")], herdrPath: "/bin/herdr"
        )
        #expect(throws: PairingError.hostKeyMismatch(
            expected: hostKey, actual: "ssh-ed25519 AAAAdifferent"
        )) {
            try mine.merging(other)
        }
    }

    @Test("a peer built from a payload carries its endpoints and identity")
    func fromPayload() {
        let payload = PairingPayload(
            name: "rawillk.air", username: "ravil",
            endpoints: [Endpoint(host: "rawillkair.local"), Endpoint(host: "100.101.102.103")],
            enrollmentSeed: Data(repeating: 3, count: 32),
            hostKey: hostKey
        )
        let built = PairedPeer(payload: payload)
        #expect(built.hostKey == hostKey)
        #expect(built.endpoints.count == 2)
        #expect(built.lastGoodEndpoint == nil)
        // herdrPath no longer travels in the QR: the phone resolves it on
        // first connect, so a freshly paired peer has none yet.
        #expect(built.herdrPath == nil)
    }
}

@Suite("Endpoint selection")
struct EndpointSelectionTests {

    private func peer(_ hosts: [String], lastGood: String? = nil) -> PairedPeer {
        PairedPeer(
            hostKey: "ssh-ed25519 AAAAx", name: "n", username: "u",
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
