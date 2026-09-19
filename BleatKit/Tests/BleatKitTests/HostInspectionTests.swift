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

    /// `KnownHostsStore` compares the OpenSSH `<algorithm> <base64>` string —
    /// `PinningHostKeyValidator` builds exactly that via
    /// `String(openSSHPublicKey:)`. A `SHA256:` fingerprint can only be shown,
    /// never matched, so this is the form the QR has to carry.
    @Test("the pin form is the OpenSSH string, with any comment dropped")
    func openSSHForm() throws {
        let base = try #require(String(data: Fixture.data("ssh_host_ed25519_key.pub"), encoding: .utf8))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let line = try #require(SSHPublicKeyLine(line: base + " some-comment"))
        #expect(line.openSSHForm == base)
        #expect(!line.openSSHForm.contains("some-comment"))
        // And it round-trips: the pin form parses back to the same key.
        #expect(try #require(SSHPublicKeyLine(line: line.openSSHForm)).fingerprint == line.fingerprint)
    }

    /// NIOSSH will not negotiate `ssh-rsa` at all, and the check is on the
    /// parsed algorithm rather than the filename: an `ssh_host_ed25519_key.pub`
    /// holding an RSA line would otherwise be accepted and fail only as a
    /// handshake error on the phone.
    @Test("negotiability is decided by the key, not its filename")
    func negotiable() throws {
        let text = try #require(String(data: Fixture.data("ssh_host_ed25519_key.pub"), encoding: .utf8))
        #expect(try #require(SSHPublicKeyLine(line: text)).isNegotiable)
        #expect(SSHPublicKeyLine.negotiableAlgorithms.first == "ssh-ed25519")
        #expect(!SSHPublicKeyLine.negotiableAlgorithms.contains("ssh-rsa"))
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
        en5: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
        \tinet6 2a00:beef::1%en5 prefixlen 64 autoconf secured
        """
        #expect(InterfaceAddresses.endpoints(ifconfigOutput: output).map(\.host) == ["2a00:beef::1"])
    }

    @Test("a Tailscale address on a utun interface is kept and classified as overlay")
    func keepsTailscale() {
        let output = """
        utun4: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1280
        \tinet 100.101.102.103 --> 100.101.102.103 netmask 0xff000000
        """
        let found = InterfaceAddresses.endpoints(ifconfigOutput: output)
        #expect(found.map(\.host) == ["100.101.102.103"])
        #expect(found.first?.reach == .overlay)
    }

    /// A Mac running Parallels, VMware or UTM has `bridge100`/`vmnet1` holding
    /// host-only addresses that pass every other filter. Offering one costs the
    /// phone a connect timeout — and if its own LAN overlaps that range it
    /// reaches an unrelated device and fails host key verification, which reads
    /// as a security warning rather than a bad address.
    @Test("host-only virtual interfaces contribute nothing")
    func skipsVirtualInterfaces() {
        let output = """
        bridge100: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
        \tinet 192.168.64.1 netmask 0xffffff00 broadcast 192.168.64.255
        vmnet1: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
        \tinet 10.211.55.2 netmask 0xffffff00 broadcast 10.211.55.255
        en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
        \tinet 192.168.11.54 netmask 0xffffff00 broadcast 192.168.11.255
        """
        #expect(InterfaceAddresses.endpoints(ifconfigOutput: output).map(\.host) == ["192.168.11.54"])
    }

    /// Linux's net-tools `ifconfig` has another layout — two spaces before
    /// `mtu`, `inet6 <addr>  prefixlen 64` rather than `inet6 <addr>%scope` —
    /// and the parser reads it. Captured on a Raspberry Pi running Debian.
    @Test("a Linux host's ifconfig yields its LAN and global addresses")
    func readsLinuxIfconfig() throws {
        let text = try #require(String(data: Fixture.data("ifconfig-linux-docker.txt"), encoding: .utf8))
        #expect(InterfaceAddresses.endpoints(ifconfigOutput: text).map(\.host) == [
            "192.168.11.67", "2a00:f3c:5ad0:0:2ecf:67ff:fec0:fa8c",
        ])
    }

    /// In the capture `docker0` is not `RUNNING`, because no container was.
    /// Starting one flips that, and without the prefix rule `172.17.0.1` would
    /// be offered to the phone. The flags are the capture's own `wlan0` ones.
    @Test("docker0 contributes nothing even while a container runs")
    func skipsDockerBridge() throws {
        let text = try #require(String(data: Fixture.data("ifconfig-linux-docker.txt"), encoding: .utf8))
        let running = text.replacingOccurrences(
            of: "docker0: flags=4099<UP,BROADCAST,MULTICAST>",
            with: "docker0: flags=4163<UP,BROADCAST,RUNNING,MULTICAST>"
        )
        #expect(running != text)
        #expect(!InterfaceAddresses.endpoints(ifconfigOutput: running).map(\.host).contains("172.17.0.1"))
    }

    /// A down interface still prints its last address. Without the flag check a
    /// disconnected Ethernet port contributes a stale endpoint that the phone
    /// patiently times out on.
    @Test("an interface that is not UP and RUNNING contributes nothing")
    func skipsDownInterfaces() {
        let down = """
        en4: flags=8822<BROADCAST,SMART,SIMPLEX,MULTICAST> mtu 1500
        \tinet 192.168.99.9 netmask 0xffffff00 broadcast 192.168.99.255
        """
        #expect(InterfaceAddresses.endpoints(ifconfigOutput: down).isEmpty)

        // UP but not RUNNING: cable unplugged.
        let noCable = """
        en4: flags=8863<UP,BROADCAST,SMART,SIMPLEX,MULTICAST> mtu 1500
        \tinet 192.168.99.9 netmask 0xffffff00 broadcast 192.168.99.255
        """
        #expect(InterfaceAddresses.endpoints(ifconfigOutput: noCable).isEmpty)
    }

    /// `fe80::/10` is `fe80`–`febf`. macOS only prints `fe80`, but matching the
    /// real range costs nothing.
    @Test("the whole fe80::/10 range counts as link-local, not just fe80")
    func fullLinkLocalRange() {
        for prefix in ["fe80", "fe90", "fea0", "febf"] {
            let output = """
            en5: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
            \tinet6 \(prefix)::1 prefixlen 64 secured
            """
            #expect(InterfaceAddresses.endpoints(ifconfigOutput: output).isEmpty, "\(prefix)")
        }
        // fec0 is outside the range and is a normal (if deprecated) address.
        let outside = """
        en5: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
        \tinet6 fec0::1 prefixlen 64 secured
        """
        #expect(InterfaceAddresses.endpoints(ifconfigOutput: outside).map(\.host) == ["fec0::1"])
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

@Suite("ssh-keyscan output")
struct KeyscanParsingTests {

    /// Real output from `ssh-keyscan -t ed25519 -p 22 127.0.0.1` against this
    /// Mac, banner line included.
    private let real = """
    # 127.0.0.1:22 SSH-2.0-OpenSSH_10.3
    127.0.0.1 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBPdxsAyNEaNtfx47Futg4ERIBkkAsvtWfxnTeKq0jct
    """

    @Test("the key is read out of real keyscan output, banner and host field ignored")
    func parsesReal() throws {
        let line = try #require(SSHPublicKeyLine.preferred(inKeyscanOutput: real))
        #expect(line.algorithm == "ssh-ed25519")
        #expect(line.fingerprint == "SHA256:5kgLcSfLx2/OaEHRcfc7PhrQ2uLNlTc8aL19AfjYn78")
    }

    /// The order the server lists keys in says nothing about what the phone
    /// will negotiate — NIOSSH walks its own preference list. Taking the first
    /// line would pin a key the phone never sees.
    @Test("preference follows NIOSSH's order, not the server's listing order")
    func prefersNegotiationOrder() throws {
        let ecdsaFirst = """
        # 127.0.0.1:22 SSH-2.0-OpenSSH_10.3
        127.0.0.1 ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBHh4
        127.0.0.1 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBPdxsAyNEaNtfx47Futg4ERIBkkAsvtWfxnTeKq0jct
        """
        #expect(try #require(SSHPublicKeyLine.preferred(inKeyscanOutput: ecdsaFirst)).algorithm == "ssh-ed25519")
    }

    /// An RSA-only host cannot be paired, so nothing is returned rather than a
    /// key the phone could never negotiate.
    @Test("an RSA-only host yields no usable key")
    func rsaOnly() {
        let rsa = """
        # 127.0.0.1:22 SSH-2.0-OpenSSH_10.3
        127.0.0.1 ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDexample
        """
        #expect(SSHPublicKeyLine.preferred(inKeyscanOutput: rsa) == nil)
    }

    @Test("empty or banner-only output yields nothing")
    func empty() {
        #expect(SSHPublicKeyLine.preferred(inKeyscanOutput: "") == nil)
        #expect(SSHPublicKeyLine.preferred(inKeyscanOutput: "# 127.0.0.1:2222 nothing here") == nil)
    }
}
