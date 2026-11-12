import Crypto
import Foundation
import Testing
@testable import BleatKit

@Suite("SSH host spec")
struct SSHHostTests {

    @Test("user@host defaults to port 22")
    func plain() throws {
        let host = try SSHHost(parsing: "robin@10.0.0.5")
        #expect(host.username == "robin")
        #expect(host.hostname == "10.0.0.5")
        #expect(host.port == 22)
    }

    @Test("explicit port")
    func withPort() throws {
        let host = try SSHHost(parsing: "robin@10.0.0.5:2222")
        #expect(host.hostname == "10.0.0.5")
        #expect(host.port == 2222)
    }

    @Test("a bare IPv6 literal is not split on its own colons")
    func ipv6() throws {
        // Splitting on the last colon would read this as host "fe80:" port 1.
        let host = try SSHHost(parsing: "robin@fe80::1")
        #expect(host.hostname == "fe80::1")
        #expect(host.port == 22)
    }

    @Test("bracketed IPv6 carries an explicit port")
    func ipv6Bracketed() throws {
        let host = try SSHHost(parsing: "robin@[fe80::1]:2222")
        #expect(host.hostname == "fe80::1")
        #expect(host.port == 2222)
    }

    @Test("rejects malformed specs", arguments: [
        "10.0.0.5",        // no user
        "robin@",          // no host
        "@10.0.0.5",       // empty user
    ])
    func rejects(_ spec: String) {
        #expect(throws: (any Error).self) { try SSHHost(parsing: spec) }
    }

    @Test("rejects an out-of-range port")
    func badPort() {
        #expect(throws: SSHHostParseError.badPort("robin@h:99999")) {
            try SSHHost(parsing: "robin@h:99999")
        }
    }

    @Test("pin key is host and port, so two ports on one host pin separately")
    func pinKey() throws {
        #expect(try SSHHost(parsing: "a@h:22").pinKey == "h:22")
        #expect(try SSHHost(parsing: "a@h:2222").pinKey == "h:2222")
    }
}

@Suite("Remote command quoting")
struct RemoteCommandTests {

    @Test("arguments are single-quoted so a shell cannot reinterpret them")
    func quoting() {
        #expect(SSHTransport.quote("plain") == "'plain'")
        #expect(SSHTransport.quote("two words") == "'two words'")
        #expect(SSHTransport.quote("semi; rm -rf /") == "'semi; rm -rf /'")
        #expect(SSHTransport.quote("$(whoami)") == "'$(whoami)'")
    }

    @Test("a quote in an argument cannot break out of the quoting")
    func quoteEscape() throws {
        // The classic injection: a target containing a single quote.
        let escaped = SSHTransport.quote("w1:p1'; touch /tmp/pwned; '")
        #expect(escaped.hasPrefix("'") && escaped.hasSuffix("'"))
        #expect(escaped.contains(#"'\''"#))
        // No bare quote survives to terminate the literal early.
        let interior = escaped.dropFirst().dropLast()
        #expect(!interior.contains("'") || interior.contains(#"'\''"#))
    }
}
