import Foundation
import Testing
@testable import BleatKit

@Suite("SSH public key lines")
struct SSHPublicKeyLineTests {

    /// The dev Mac's real host key, captured into `Fixtures/`, checked against
    /// what `ssh-keygen -lf` printed for the same file. Pinning against the
    /// tool's own output is the point: the fingerprint is easy to get subtly
    /// wrong in ways that still look like valid base64, and a wrong one would
    /// make every pairing fail with a host key mismatch.
    @Test("the fingerprint matches what ssh-keygen prints for the same file")
    func matchesSSHKeygen() throws {
        let text = try #require(String(data: Fixture.data("ssh_host_ed25519_key.pub"), encoding: .utf8))
        let line = try #require(SSHPublicKeyLine(line: text))
        #expect(line.algorithm == "ssh-ed25519")
        #expect(line.fingerprint == "SHA256:5kgLcSfLx2/OaEHRcfc7PhrQ2uLNlTc8aL19AfjYn78")
    }

    /// The captured file has a trailing space and no comment, which is what
    /// macOS writes.
    @Test("a key with no comment parses, and the trailing space is not one")
    func noComment() throws {
        let text = try #require(String(data: Fixture.data("ssh_host_ed25519_key.pub"), encoding: .utf8))
        let line = try #require(SSHPublicKeyLine(line: text))
        #expect(line.comment == nil)
    }

    @Test("a comment is kept, including spaces within it")
    func withComment() throws {
        let base = try #require(String(data: Fixture.data("ssh_host_ed25519_key.pub"), encoding: .utf8))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let line = try #require(SSHPublicKeyLine(line: base + " root@rawillk air"))
        #expect(line.comment == "root@rawillk air")
        // A comment must not change the fingerprint: it is not in the blob.
        #expect(line.fingerprint == "SHA256:5kgLcSfLx2/OaEHRcfc7PhrQ2uLNlTc8aL19AfjYn78")
    }

    /// The algorithm appears twice — as the text label and as the first field
    /// inside the blob. A line where they disagree is malformed, and trusting
    /// either one would mean pinning a fingerprint for a key of a different
    /// type than the label claims.
    @Test("a label that disagrees with the blob is rejected")
    func mismatchedLabel() throws {
        let base = try #require(String(data: Fixture.data("ssh_host_ed25519_key.pub"), encoding: .utf8))
        let fields = base.split(separator: " ")
        #expect(SSHPublicKeyLine(line: "ecdsa-sha2-nistp256 \(fields[1])") == nil)
    }

    @Test("junk is rejected rather than half-parsed")
    func rejectsJunk() {
        for text in ["", "ssh-ed25519", "ssh-ed25519 not-base64!!", "just one field"] {
            #expect(SSHPublicKeyLine(line: text) == nil, "\(text)")
        }
    }
}

@Suite("Interface addresses")
struct InterfaceAddressesTests {

    private func endpoints() throws -> [Endpoint] {
        let text = try #require(String(data: Fixture.data("ifconfig.txt"), encoding: .utf8))
        return InterfaceAddresses.endpoints(ifconfigOutput: text)
    }

    /// The dev Mac's real `ifconfig` has 30-odd addresses across 20-odd
    /// interfaces, and exactly two of them are usable endpoints. Everything
    /// else is loopback, link-local, deprecated or temporary.
    @Test("a real ifconfig yields only the addresses a phone could reach")
    func realOutput() throws {
        #expect(try endpoints().map(\.host) == [
            "192.168.11.54",
            "2a00:f3c:5ad0:0:c29:6db5:4a49:dc53",
        ])
    }

    /// The finding that motivates the filter. `2a00:…:49c5:c03a:bea8:3706` is
    /// an RFC 4941 privacy address: it rotates by design, so recording it as an
    /// endpoint yields a peer that works today and fails tomorrow with nothing
    /// to show why.
    @Test("temporary privacy addresses are excluded, since they rotate")
    func skipsTemporary() throws {
        let hosts = try endpoints().map(\.host)
        #expect(!hosts.contains("2a00:f3c:5ad0:0:49c5:c03a:bea8:3706"))
        #expect(!hosts.contains("2a00:f3c:5ad0:0:bdf2:4ccc:1b87:c0e"))   // deprecated too
    }

    @Test("link-local, loopback and AWDL interfaces contribute nothing")
    func skipsUnusable() throws {
        let hosts = try endpoints().map(\.host)
        #expect(!hosts.contains { $0.hasPrefix("fe80:") })
        #expect(!hosts.contains("127.0.0.1"))
        #expect(!hosts.contains("::1"))
    }

    @Test("the scope id is stripped from an address that carries one")
    func stripsScope() {
        let output = """
        en5: flags=8863<UP> mtu 1500
        \tinet6 2a00:beef::1%en5 prefixlen 64 autoconf secured
        """
        #expect(InterfaceAddresses.endpoints(ifconfigOutput: output).map(\.host) == ["2a00:beef::1"])
    }

    @Test("a Tailscale address on a utun interface is kept and classified as overlay")
    func keepsTailscale() {
        let output = """
        utun4: flags=8051<UP> mtu 1280
        \tinet 100.101.102.103 --> 100.101.102.103 netmask 0xff000000
        """
        let found = InterfaceAddresses.endpoints(ifconfigOutput: output)
        #expect(found.map(\.host) == ["100.101.102.103"])
        #expect(found.first?.reach == .overlay)
    }

    @Test("the port is applied to every endpoint")
    func appliesPort() throws {
        let text = try #require(String(data: Fixture.data("ifconfig.txt"), encoding: .utf8))
        #expect(InterfaceAddresses.endpoints(ifconfigOutput: text, port: 2222).allSatisfy { $0.port == 2222 })
    }

    @Test("empty output yields no endpoints rather than a bogus one")
    func empty() {
        #expect(InterfaceAddresses.endpoints(ifconfigOutput: "").isEmpty)
    }
}
