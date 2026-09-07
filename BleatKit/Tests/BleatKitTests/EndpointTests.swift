import Foundation
import Testing
@testable import BleatKit

@Suite("Endpoint reachability")
struct EndpointTests {

    /// The half of the old `.lan` case that no VPN can help with. Multicast is
    /// scoped to its link; a loopback address names this device and a
    /// link-local one names this wire. A tunnel routes none of them.
    ///
    /// Loopback belonging here rather than with the private addresses is the
    /// load-bearing part: filed as private, `127.0.0.1:2222` — the address this
    /// repo's own throwaway-sshd procedure uses, and one a user can add by hand
    /// — would become a candidate the moment any tunnel came up and cost a full
    /// TCP timeout in the race for a destination that cannot exist.
    @Test("link-scoped names and addresses need the link, and no tunnel changes that")
    func linkScoped() {
        for host in [
            "rawillkair.local", "rawillkair.local.", "RawillkAir.Local",
            "127.0.0.1", "127.1.2.3", "localhost", "::1",
            "169.254.1.1", "fe80::1",
        ] {
            let endpoint = Endpoint(host: host)
            #expect(endpoint.reach == .linkScoped, "\(host)")
            // Still usable on the link: `bleat redeem` against a throwaway sshd
            // on 127.0.0.1:2222 is a documented flow.
            #expect(endpoint.isUsable(from: .localLink), "\(host)")
            #expect(!endpoint.isUsable(from: .offLink), "\(host)")
            #expect(
                !endpoint.isUsable(from: LinkState(onLocalLink: false, tunnelActive: true)),
                "\(host)"
            )
            // And never a reason to blame a VPN, from anywhere.
            #expect(!endpoint.needsTunnel(from: .localLink), "\(host)")
            #expect(!endpoint.needsTunnel(from: .offLink), "\(host)")
        }
    }

    /// The other half, and the one that changed. A private address is not
    /// unreachable off the link — it is unreachable *unaided*. A zero-trust
    /// client like Twingate routes exactly this, and gives the host no address
    /// of its own to discover, so dropping it on cellular discarded the only
    /// candidate that would have connected.
    @Test("private addresses need the link or a tunnel")
    func privateAddresses() {
        for host in [
            "192.168.11.54", "10.0.0.5", "172.16.0.1", "172.31.255.254",
            "fd00::1", "fc00::1",
        ] {
            let endpoint = Endpoint(host: host)
            #expect(endpoint.reach == .privateAddress, "\(host)")
            #expect(endpoint.isUsable(from: .localLink), "\(host)")
            #expect(!endpoint.isUsable(from: .offLink), "\(host)")
            #expect(
                endpoint.isUsable(from: LinkState(onLocalLink: false, tunnelActive: true)),
                "\(host)"
            )
        }
    }

    /// `needsTunnel(from:)` is link-dependent, and that is the whole point of
    /// it being a function. On Wi-Fi a private address is simply the network
    /// the phone is standing on, so a failure there means the host is asleep —
    /// blaming a VPN would send the user to fix something that is not broken.
    /// A mesh address needs the tunnel from everywhere, including Wi-Fi, which
    /// is the case a plain "are we off-link" flag got wrong.
    @Test("whether an endpoint needs a tunnel depends on where the phone is")
    func needsTunnelIsLinkDependent() {
        let privateAddress = Endpoint(host: "192.168.11.54")
        #expect(!privateAddress.needsTunnel(from: .localLink))
        #expect(privateAddress.needsTunnel(from: .offLink))

        let mesh = Endpoint(host: "100.101.102.103")
        #expect(mesh.needsTunnel(from: .localLink))
        #expect(mesh.needsTunnel(from: .offLink))

        #expect(!Endpoint(host: "herdr.dev").needsTunnel(from: .offLink))
    }

    /// `isUsableOffLink` is the strictest question — cellular, no tunnel — and
    /// it is what `bleat inspect` warns on. Both of the old `.lan` kinds fail
    /// it, which is why that warning still fires on the same hosts.
    @Test("both local-only kinds fail the unaided-cellular test")
    func unaidedCellular() {
        #expect(!Endpoint(host: "mac.local").isUsableOffLink)
        #expect(!Endpoint(host: "192.168.11.54").isUsableOffLink)
        #expect(!Endpoint(host: "127.0.0.1").isUsableOffLink)
        #expect(Endpoint(host: "100.101.102.103").isUsableOffLink)
    }

    /// The case that makes this classification worth having. Tailscale's
    /// ranges look private to the usual tests — CGNAT is not RFC1918 but is
    /// non-global, and its v6 range is a ULA — yet they are the *only* thing
    /// that works on cellular. Filing them under `.lan` would drop the one
    /// usable endpoint.
    @Test("Tailscale ranges are overlay, not LAN")
    func tailscaleIsOverlay() {
        for host in [
            "100.64.0.1", "100.101.102.103", "100.127.255.255",
            "fd7a:115c:a1e0::1", "fd7a:115c:a1e0:ab12:4843:cd96:0:1",
            "rawillk-air.tailnet-1234.ts.net",
        ] {
            #expect(Endpoint(host: host).reach == .overlay, "\(host)")
            #expect(Endpoint(host: host).isUsableOffLink, "\(host)")
        }
    }

    @Test("172.x outside 16...31 is public, and 100.x outside the CGNAT range is not Tailscale")
    func boundaries() {
        #expect(Endpoint(host: "172.15.0.1").reach == .routable)
        #expect(Endpoint(host: "172.32.0.1").reach == .routable)
        #expect(Endpoint(host: "100.63.0.1").reach == .routable)
        #expect(Endpoint(host: "100.128.0.1").reach == .routable)
    }

    /// `fdisk.example.com` starts with "fd" and `fcbank.com` with "fc", but a
    /// ULA prefix only means anything in something that is actually an address.
    @Test("hostnames that merely start like IPv6 prefixes stay routable")
    func hostnamesAreNotAddresses() {
        for host in ["fdisk.example.com", "fcbank.com", "fe80s-diner.example"] {
            #expect(Endpoint(host: host).reach == .routable, "\(host)")
        }
    }

    @Test("global addresses and public names are routable")
    func routable() {
        for host in ["2a00:f3c:5ad0:0:c29:6db5:4a49:dc53", "herdr.dev", "203.0.113.7"] {
            #expect(Endpoint(host: host).reach == .routable, "\(host)")
        }
    }
}

@Suite("Endpoint parsing")
struct EndpointParsingTests {

    @Test("host, host:port, and bracketed IPv6 all round-trip")
    func roundTrip() throws {
        let cases: [(String, String, Int)] = [
            ("herdr.dev", "herdr.dev", 22),
            ("herdr.dev:2222", "herdr.dev", 2222),
            ("192.168.11.54:22", "192.168.11.54", 22),
            ("[fe80::1]:2222", "fe80::1", 2222),
            ("[fe80::1]", "fe80::1", 22),
            ("fe80::1", "fe80::1", 22),
        ]
        for (text, host, port) in cases {
            let endpoint = try #require(Endpoint(string: text), "\(text)")
            #expect(endpoint.host == host, "\(text)")
            #expect(endpoint.port == port, "\(text)")
            // The description must parse back to the same thing.
            #expect(Endpoint(string: endpoint.description) == endpoint, "\(text)")
        }
    }

    @Test("IPv6 is bracketed in the description so a port stays unambiguous")
    func bracketsIPv6() {
        #expect(Endpoint(host: "fe80::1", port: 2222).description == "[fe80::1]:2222")
        // Bracketed even without a port, or a bare literal would be ambiguous
        // to anything reading it back.
        #expect(Endpoint(host: "fe80::1").description == "[fe80::1]")
    }

    /// `:22` on every endpoint is three characters each, and the QR pays for
    /// all of them. Omitting it is safe because `Endpoint(string:)` defaults to
    /// 22, so the form still round-trips.
    @Test("the default port is left out, and a non-default one is kept")
    func omitsDefaultPort() {
        #expect(Endpoint(host: "herdr.dev").description == "herdr.dev")
        #expect(Endpoint(host: "herdr.dev", port: 2222).description == "herdr.dev:2222")
        for endpoint in [Endpoint(host: "herdr.dev"), Endpoint(host: "fe80::1"),
                         Endpoint(host: "herdr.dev", port: 2222),
                         Endpoint(host: "fe80::1", port: 2222)] {
            #expect(Endpoint(string: endpoint.description) == endpoint, "\(endpoint)")
        }
    }

    /// `description` *is* the wire format — `PairingPayload` encodes endpoints
    /// as `map(\.description)`. Without the `CustomStringConvertible`
    /// conformance, interpolation yields the synthesised reflection instead,
    /// which will not parse back; for IPv6 that would reject a whole payload.
    @Test("interpolation produces the wire format, not the synthesised reflection")
    func interpolationIsTheWireFormat() throws {
        let endpoint = Endpoint(host: "fe80::1", port: 2222)
        #expect("\(endpoint)" == "[fe80::1]:2222")
        #expect(String(describing: endpoint) == "[fe80::1]:2222")
        #expect(Endpoint(string: "\(endpoint)") == endpoint)
    }

    /// `--endpoint host` alongside `--port 2222` means that host on 2222.
    /// Defaulting it to 22 would produce an endpoint that looks right in the
    /// list and refuses every connection.
    @Test("an endpoint with no port of its own inherits the supplied default")
    func inheritsDefaultPort() throws {
        #expect(try #require(Endpoint(string: "herdr.dev", defaultPort: 2222)).port == 2222)
        #expect(try #require(Endpoint(string: "fe80::1", defaultPort: 2222)).port == 2222)
        #expect(try #require(Endpoint(string: "[fe80::1]", defaultPort: 2222)).port == 2222)
        // An explicit port always wins over the default.
        #expect(try #require(Endpoint(string: "herdr.dev:22", defaultPort: 2222)).port == 22)
        #expect(try #require(Endpoint(string: "[fe80::1]:22", defaultPort: 2222)).port == 22)
    }

    @Test("nonsense is rejected rather than guessed at")
    func rejects() {
        for text in ["", "   ", "herdr.dev:0", "herdr.dev:70000", "herdr.dev:port", "[fe80::1", "[]:22", ":22"] {
            #expect(Endpoint(string: text) == nil, "\(text)")
        }
    }
}
