import Crypto
import Foundation
import Testing
@testable import BleatKit

@Suite("Device SSH key")
struct SSHKeyPairTests {

    /// A real key produced by `ssh-keygen -t ed25519 -C bleat-verify`, with the
    /// public line and fingerprint exactly as OpenSSH printed them. Pinning
    /// against real tool output is the point: both encodings are easy to get
    /// subtly wrong in ways that still look like valid base64.
    private enum Vector {
        static let rawPrivateHex = "6698e0c6650a48a716a64b9f6dc07b085077ed0f63ef9c7c88f93ed72a7b017f"
        static let publicLine = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGlTV9e28fXOIGuNms5s28q/bzHGqmfwkux/FpfmGmsz bleat-verify"
        static let fingerprint = "SHA256:uMJ6mz1AVHlndB0iw9IZmvVT9fCpEiJneOvsJbu6EDw"
    }

    private func vectorPair() throws -> SSHKeyPair {
        var bytes = Data()
        var index = Vector.rawPrivateHex.startIndex
        while index < Vector.rawPrivateHex.endIndex {
            let next = Vector.rawPrivateHex.index(index, offsetBy: 2)
            bytes.append(UInt8(Vector.rawPrivateHex[index..<next], radix: 16)!)
            index = next
        }
        return try SSHKeyPair(rawRepresentation: bytes)
    }

    @Test("the public line matches ssh-keygen byte for byte")
    func authorizedKeyLine() throws {
        #expect(try vectorPair().authorizedKeyLine(comment: "bleat-verify") == Vector.publicLine)
    }

    @Test("the fingerprint matches `ssh-keygen -l`")
    func fingerprint() throws {
        // OpenSSH hashes the whole wire-format blob, not the bare 32-byte key.
        // Hashing the raw key produced a plausible SHA256: string that matched
        // nothing on the host — worse than showing nothing.
        #expect(try vectorPair().fingerprint == Vector.fingerprint)
    }

    @Test("an empty comment omits the trailing space")
    func noComment() throws {
        let line = try vectorPair().authorizedKeyLine(comment: "")
        #expect(line.split(separator: " ").count == 2)
        #expect(!line.hasSuffix(" "))
    }

    @Test("a key survives a round trip through its raw representation")
    func roundTrip() throws {
        let original = SSHKeyPair()
        let restored = try SSHKeyPair(rawRepresentation: original.rawRepresentation)
        #expect(restored.authorizedKeyLine() == original.authorizedKeyLine())
        #expect(restored.fingerprint == original.fingerprint)
    }

    @Test("two generated keys differ")
    func distinct() {
        #expect(SSHKeyPair().fingerprint != SSHKeyPair().fingerprint)
    }

    @Test("a comment cannot inject a second authorized_keys entry")
    func commentInjection() throws {
        // A newline in the comment would append a whole extra key line to the
        // host's authorized_keys when this is echoed into it.
        let line = try vectorPair().authorizedKeyLine(
            comment: "evil\nssh-ed25519 AAAAattacker attacker@host"
        )
        #expect(!line.contains("\n"))
        #expect(line.split(separator: "\n").count == 1)
    }

    @Test("a comment cannot break the quoted shell instruction")
    func commentQuoting() throws {
        // The app renders `echo '<line>' >> ~/.ssh/authorized_keys`; a quote
        // would end the literal early.
        let line = try vectorPair().authorizedKeyLine(comment: "a'; rm -rf ~; '")
        #expect(!line.contains("'"))
        #expect(!line.contains("\""))
        #expect(!line.contains("`"))
        #expect(!line.contains("$"))
    }

    @Test("a comment stays one token")
    func commentSpacing() throws {
        let line = try vectorPair().authorizedKeyLine(comment: "my phone")
        #expect(line.split(separator: " ").count == 3)
    }

    @Test("a comment of only unsafe characters degrades to no comment")
    func commentAllStripped() throws {
        let line = try vectorPair().authorizedKeyLine(comment: "\n\n")
        #expect(line.split(separator: " ").count == 2)
        #expect(!line.hasSuffix(" "))
    }

    @Test("the line is a single line, safe to append to authorized_keys")
    func singleLine() throws {
        let line = try vectorPair().authorizedKeyLine(comment: "bleat")
        #expect(!line.contains("\n"))
        #expect(line.hasPrefix("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5"))
    }
}
