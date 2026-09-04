import Foundation
import Testing
@testable import BleatKit

@Suite("Endpoint reachability")
struct EndpointTests {

    @Test("mDNS names and private addresses are link-local")
    func linkLocal() {
        for host in [
            "rawillkair.local", "rawillkair.local.", "RawillkAir.Local",
            "192.168.11.54", "10.0.0.5", "172.16.0.1", "172.31.255.254",
            "169.254.1.1", "127.0.0.1", "localhost",
            "fe80::1", "::1",
        ] {
            #expect(Endpoint(host: host).reach == .lan, "\(host)")
            #expect(!Endpoint(host: host).isUsableOffLink, "\(host)")
        }
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
