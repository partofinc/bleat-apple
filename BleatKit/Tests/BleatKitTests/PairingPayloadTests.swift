import Crypto
import Foundation
import Testing
@testable import BleatKit

@Suite("Pairing payload")
struct PairingPayloadTests {

    /// The dev Mac's real host key, in the OpenSSH form the pin store compares.
    static let hostKey =
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBPdxsAyNEaNtfx47Futg4ERIBkkAsvtWfxnTeKq0jct"

    private func sample(version: Int = PairingPayload.currentVersion) -> PairingPayload {
        PairingPayload(
            version: version,
            name: "rawillk.air",
            username: "ravil",
            endpoints: [
                Endpoint(host: "rawillkair.local"),
                Endpoint(host: "192.168.11.54"),
                Endpoint(host: "100.101.102.103"),
                Endpoint(host: "2a00:f3c:5ad0:0:c29:6db5:4a49:dc53", port: 2222),
            ],
            enrollmentSeed: Data(repeating: 0xA7, count: 32),
            hostKey: Self.hostKey
        )
    }

    private func mutated(_ transform: (inout Data) -> Void) throws -> String {
        var wire = try PairingWire.encode(sample())
        transform(&wire)
        return "bleat://pair?d=" + PairingPayload.base64URLEncode(wire)
    }

    @Test("a payload survives the trip through a QR string")
    func roundTrip() throws {
        let original = sample()
        let decoded = try PairingPayload(urlString: try original.urlString())
        #expect(decoded == original)
        #expect(decoded.endpoints.map(\.description) == original.endpoints.map(\.description))
    }

    @Test("the seed rebuilds the enrollment key")
    func seedRebuildsKey() throws {
        let pair = SSHKeyPair()
        let payload = PairingPayload(
            name: "n", username: "u", endpoints: [Endpoint(host: "h.local")],
            enrollmentSeed: pair.rawRepresentation, hostKey: Self.hostKey)
        let decoded = try PairingPayload(urlString: try payload.urlString())
        #expect(try decoded.enrollmentKey().fingerprint == pair.fingerprint)
    }

    /// Every byte in the QR is modules, and modules are terminal rows the user
    /// may not have. The budget is measured, not guessed: with the binary wire
    /// format the four-endpoint sample below is well under 300 characters,
    /// which is a version 9-10 code at correction L. Blowing this means the
    /// format grew — re-measure before raising it.
    @Test("a realistic payload stays small enough to scan easily")
    func staysSmall() throws {
        let text = try sample().urlString()
        #expect(text.count <= 300, "pairing URL grew to \(text.count) characters")
    }

    /// Structure is not free here. JSON keys, quotes and braces were about
    /// forty characters and base64 then inflated the whole thing by a third;
    /// both ends of this format ship together, so there is nothing to negotiate
    /// and no reason to pay for self-description.
    @Test("the binary form carries little beyond the two keys")
    func binaryIsCompact() throws {
        let wire = try PairingWire.encode(sample())
        // 3-byte header + 32-byte seed + 32-byte key is irreducible.
        #expect(wire.count >= 67)
        #expect(wire.count < 200, "wire grew to \(wire.count) bytes")
    }

    @Test("the URL uses a scheme the system camera can hand to the app")
    func urlShape() throws {
        let text = try sample().urlString()
        #expect(text.hasPrefix("bleat://pair?d="))
        let encoded = text.replacingOccurrences(of: "bleat://pair?d=", with: "")
        #expect(!encoded.contains("+") && !encoded.contains("/") && !encoded.contains("="))
    }

    @Test("something that is not a Bleat code is distinguished from a broken one")
    func notAPairingCode() {
        for text in ["https://herdr.dev", "WIFI:S:home;T:WPA;P:x;;", "", "bleat://other?d=aaaa"] {
            #expect(throws: PairingError.notAPairingCode) { try PairingPayload(urlString: text) }
        }
    }

    @Test("a damaged code is rejected, never half-decoded")
    func malformed() {
        for text in ["bleat://pair", "bleat://pair?d=", "bleat://pair?d=not-base64-@@@"] {
            #expect(throws: PairingError.malformedPairingCode) { try PairingPayload(urlString: text) }
        }
    }

    /// The scenario the version guard exists for. A newer payload may move the
    /// enrollment key or change what the host key covers, so it is named as a
    /// version problem rather than reported as damage — which would tell the
    /// user to scan again, forever.
    @Test("a newer format reports its version rather than looking damaged")
    func unsupportedVersion() throws {
        let url = try mutated { $0[0] = 99 }
        #expect(throws: PairingError.unsupportedVersion(99)) { try PairingPayload(urlString: url) }
    }

    /// The version is the first byte, so even a payload with nothing else in it
    /// is still identifiable as a version problem.
    @Test("a version byte alone is enough to report the version")
    func versionFromOneByte() {
        let url = "bleat://pair?d=" + PairingPayload.base64URLEncode(Data([7]))
        #expect(throws: PairingError.unsupportedVersion(7)) { try PairingPayload(urlString: url) }
    }

    /// The seed is a fixed 32 bytes, so a short one cannot silently yield a
    /// weaker key.
    @Test("a seed of the wrong length cannot be encoded")
    func badSeedLength() {
        let payload = PairingPayload(
            name: "n", username: "u", endpoints: [Endpoint(host: "h.local")],
            enrollmentSeed: Data(repeating: 1, count: 16), hostKey: Self.hostKey)
        #expect(throws: PairingError.malformedPairingCode) { try PairingWire.encode(payload) }
    }

    /// A host key that will not parse could never be pinned, so a payload
    /// carrying one is malformed rather than merely odd.
    @Test("an unrecognised host key kind is rejected")
    func badHostKeyRejected() throws {
        let url = try mutated { $0[34] = 9 }   // byte 34 is the host key kind
        #expect(throws: PairingError.malformedPairingCode) { try PairingPayload(urlString: url) }
    }

    @Test("a truncated payload is rejected rather than half-read")
    func truncated() throws {
        for keep in [1, 2, 10, 40, 60] {
            let url = try mutated { $0 = $0.prefix(keep) }
            #expect(throws: PairingError.self) { try PairingPayload(urlString: url) }
        }
    }

    /// Extra bytes mean this is not the payload it claims to be. A partial read
    /// that happened to line up would be worse than a refusal.
    @Test("trailing bytes are rejected")
    func trailingBytes() throws {
        let url = try mutated { $0.append(contentsOf: [0, 0, 0]) }
        #expect(throws: PairingError.malformedPairingCode) { try PairingPayload(urlString: url) }
    }

    @Test("a payload with no endpoints is rejected")
    func noEndpoints() throws {
        let payload = PairingPayload(
            name: "n", username: "u", endpoints: [],
            enrollmentSeed: Data(repeating: 1, count: 32), hostKey: Self.hostKey)
        let url = "bleat://pair?d=" + PairingPayload.base64URLEncode(try PairingWire.encode(payload))
        #expect(throws: PairingError.malformedPairingCode) { try PairingPayload(urlString: url) }
    }
}

@Suite("Host key on the wire")
struct HostKeyWireTests {

    private let openSSH =
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBPdxsAyNEaNtfx47Futg4ERIBkkAsvtWfxnTeKq0jct"

    /// The wire blob wraps the key in 19 bytes that say "ssh-ed25519" all over
    /// again. In a QR every byte is modules, so only the 32-byte key travels.
    @Test("an ed25519 key round-trips through its bare 32 bytes")
    func rawKeyRoundTrip() throws {
        let parsed = try #require(SSHPublicKeyLine(line: openSSH))
        let raw = try #require(parsed.ed25519RawKey)
        #expect(raw.count == 32)
        let rebuilt = try #require(SSHPublicKeyLine.ed25519(rawKey: raw))
        #expect(rebuilt.openSSHForm == openSSH)
        #expect(rebuilt.fingerprint == parsed.fingerprint)
    }

    @Test("the algorithm name is absent from the encoded payload")
    func algorithmNotOnTheWire() throws {
        let payload = PairingPayload(
            name: "n", username: "u", endpoints: [Endpoint(host: "h.local")],
            enrollmentSeed: Data(repeating: 3, count: 32), hostKey: openSSH)
        #expect(!(try PairingWire.encode(payload)).contains(Data("ssh-ed25519".utf8)))
    }

    @Test("a non-ed25519 key has no bare form and travels as its blob")
    func otherAlgorithmsKeepTheirBlob() throws {
        var blob = Data([0, 0, 0, 19])
        blob.append(Data("ecdsa-sha2-nistp256".utf8))
        blob.append(Data([0, 0, 0, 4]))
        blob.append(Data([1, 2, 3, 4]))
        let key = try #require(SSHPublicKeyLine(blob: blob))
        #expect(key.algorithm == "ecdsa-sha2-nistp256")
        #expect(key.ed25519RawKey == nil)

        // And it survives a payload round-trip through the blob branch.
        let payload = PairingPayload(
            name: "n", username: "u", endpoints: [Endpoint(host: "h.local")],
            enrollmentSeed: Data(repeating: 4, count: 32), hostKey: key.openSSHForm)
        #expect(try PairingPayload(urlString: try payload.urlString()).hostKey == key.openSSHForm)
    }

    @Test("a key of the wrong length cannot be rebuilt")
    func rejectsWrongLength() {
        #expect(SSHPublicKeyLine.ed25519(rawKey: Data(repeating: 1, count: 31)) == nil)
        #expect(SSHPublicKeyLine.ed25519(rawKey: Data()) == nil)
    }
}
