import Foundation
import Testing
@testable import BleatKit

/// Reading this machine's Tailscale identity out of `tailscale status --json`.
///
/// The fixture is a real reply with identifiers replaced: the real one carries
/// node keys, a user's email address and every peer on the tailnet, none of
/// which belongs in a repository. The shape is what is being pinned.
@Suite("Tailscale endpoints")
struct TailscaleStatusTests {

    private func endpoints(_ fixture: String, port: Int = 22) throws -> [Endpoint] {
        TailscaleStatus.endpoints(fromStatusJSON: try Fixture.data(fixture), port: port)
    }

    /// **The trailing dot is the detail that matters.** A live install returns
    /// `somemac.tailexample.ts.net.` — fully qualified — and storing that verbatim
    /// would put a stray dot in every endpoint the phone displays and dials.
    @Test("the MagicDNS name is taken without its trailing dot")
    func stripsTheTrailingDot() throws {
        let found = try endpoints("tailscale-status.json")
        let name = try #require(found.first { $0.host.hasSuffix(".ts.net") })
        #expect(name.host == "somemac.tailexample.ts.net")
        #expect(name.port == 22)
    }

    /// The name is the reason this exists: a node's address is stable only
    /// while its node record lives, and re-adding the machine to the tailnet
    /// mints a new one. Endpoints are captured at pair time and never
    /// re-discovered, so the name is what survives that.
    @Test("the name and both addresses are offered")
    func offersNameAndAddresses() throws {
        let found = try endpoints("tailscale-status.json")
        #expect(found.count == 3)
        #expect(found.contains { $0.host == "100.114.119.30" })
        #expect(found.contains { $0.host == "fd7a:115c:a1e0::42a:771f" })
    }

    /// Every one of them has to survive `endpointsToTry` on cellular, which is
    /// the only network where they are the sole thing that can work. CGNAT is
    /// not RFC1918 and the v6 range is a ULA, so the ordinary private-address
    /// tests would call both `.lan` and drop them.
    @Test("everything offered is usable off the local link")
    func allReachOffLink() throws {
        for endpoint in try endpoints("tailscale-status.json") {
            #expect(endpoint.reach == .overlay, "\(endpoint.host) was \(endpoint.reach)")
            #expect(endpoint.isUsableOffLink)
        }
    }

    /// A stopped or logged-out Tailscale still reports the last state it knew.
    /// Pairing on that would record an endpoint from a tailnet this machine may
    /// no longer be on — and later that is indistinguishable from a host that
    /// is merely switched off.
    @Test("a backend that is not running offers nothing")
    func requiresARunningBackend() throws {
        let json = Data("""
        {"BackendState": "Stopped",
         "CurrentTailnet": {"MagicDNSEnabled": true},
         "Self": {"DNSName": "somemac.tailexample.ts.net.", "TailscaleIPs": ["100.64.0.1"]}}
        """.utf8)
        #expect(TailscaleStatus.endpoints(fromStatusJSON: json, port: 22).isEmpty)
    }

    /// With MagicDNS off the name does not resolve, so storing it would add an
    /// endpoint that can only ever spend a connection timeout — the exact cost
    /// the endpoint filters exist to avoid. The addresses still work.
    @Test("with MagicDNS disabled the name is dropped and the addresses are not")
    func skipsTheNameWithoutMagicDNS() throws {
        let json = Data("""
        {"BackendState": "Running",
         "CurrentTailnet": {"MagicDNSEnabled": false},
         "Self": {"DNSName": "somemac.tailexample.ts.net.", "TailscaleIPs": ["100.64.0.1"]}}
        """.utf8)
        let found = TailscaleStatus.endpoints(fromStatusJSON: json, port: 22)
        #expect(found.map(\.host) == ["100.64.0.1"])
    }

    /// Tailscale may be absent, or a future release may move these fields.
    /// Neither is a reason to fail a pairing that has other endpoints — this is
    /// an optional extra, and CLAUDE.md's rule is that unrecognised data is
    /// never fatal.
    @Test("junk and absence both yield nothing rather than throwing")
    func toleratesRubbish() {
        for junk in ["", "not json at all", "{}", "[]", #"{"Self": null}"#] {
            #expect(TailscaleStatus.endpoints(fromStatusJSON: Data(junk.utf8), port: 22).isEmpty)
        }
    }

    /// A non-default SSH port has to reach the endpoints this makes, or a host
    /// on one would be listed at 22 and never answer.
    @Test("the port is carried through")
    func carriesThePort() throws {
        for endpoint in try endpoints("tailscale-status.json", port: 2222) {
            #expect(endpoint.port == 2222)
        }
    }
}
