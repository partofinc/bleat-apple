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
            hostKey: Self.hostKey,
            herdrPath: "/opt/homebrew/bin/herdr"
        )
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
            name: "n", username: "u",
            endpoints: [Endpoint(host: "h")],
            enrollmentSeed: pair.rawRepresentation,
            hostKey: Self.hostKey, herdrPath: "/bin/herdr"
        )
        let decoded = try PairingPayload(urlString: try payload.urlString())
        #expect(try decoded.enrollmentKey().fingerprint == pair.fingerprint)
    }

    /// Every byte in the QR is modules, and modules decide whether it scans at
    /// arm's length. A raw seed is ~44 base64 characters where an OpenSSH PEM
    /// would be ~600, and this asserts that budget rather than trusting it.
    ///
    /// The threshold is a QR size, not a round number, and it is measured
    /// against a **real payload**. An earlier version of this comment quoted
    /// versions measured with a string of `A`s, which QR encodes in
    /// alphanumeric mode at 5.5 bits per character; a `bleat://` URL is
    /// lowercase and punctuated, so it encodes in byte mode at 8 bits and
    /// comes out about 12 modules larger for the same length. Measured with
    /// `CIQRCodeGenerator` at correction level M and a 4-module quiet zone,
    /// the four-endpoint sample below is 442 characters and renders 89 modules
    /// wide — 45 terminal rows in half-blocks.
    ///
    /// Capping at 512 keeps that from growing silently. It is already large
    /// enough that `bleat pair` falls back to printing the link on a short
    /// terminal, so anything that pushes it further is worth noticing.
    @Test("a realistic payload stays small enough to scan easily")
    func staysSmall() throws {
        let text = try sample().urlString()
        #expect(text.count <= 512, "pairing URL grew to \(text.count) characters")
    }

    @Test("the URL uses a scheme the system camera can hand to the app")
    func urlShape() throws {
        let text = try sample().urlString()
        #expect(text.hasPrefix("bleat://pair?d="))
        // base64url only: no +, / or = to be mangled in transit.
        let encoded = text.replacingOccurrences(of: "bleat://pair?d=", with: "")
        #expect(!encoded.contains("+") && !encoded.contains("/") && !encoded.contains("="))
    }

    @Test("something that is not a Bleat code is distinguished from a broken one")
    func notAPairingCode() {
        for text in ["https://herdr.dev", "WIFI:S:home;T:WPA;P:x;;", "", "bleat://other?d=aaaa"] {
            #expect(throws: PairingError.notAPairingCode) {
                try PairingPayload(urlString: text)
            }
        }
    }

    @Test("a damaged code is rejected, never half-decoded")
    func malformed() {
        for text in [
            "bleat://pair",                       // no payload
            "bleat://pair?d=",                    // empty payload
            "bleat://pair?d=not-base64-@@@",
            "bleat://pair?d=" + PairingPayload.base64URLEncode(Data("{}".utf8)),
        ] {
            #expect(throws: PairingError.malformedPairingCode) {
                try PairingPayload(urlString: text)
            }
        }
    }

    /// Half-understanding a newer code is worse than refusing it: a later
    /// version may move the enrollment key or change what the fingerprint
    /// covers, and both are load-bearing for security.
    @Test("a newer format is refused rather than partially read")
    func unsupportedVersion() throws {
        let text = try sample(version: 99).urlString()
        #expect(throws: PairingError.unsupportedVersion(99)) {
            try PairingPayload(urlString: text)
        }
    }

    /// The scenario the version guard exists for, and the one it used to get
    /// wrong: a v2 code that *moved* the enrollment key. Decoding first meant
    /// dying on the missing field and reporting `malformedPairingCode`, which
    /// tells the user to scan again — forever — instead of to update the app.
    @Test("a newer format that moved a field still reports the version, not damage")
    func unsupportedVersionBeatsMissingFields() {
        let v2 = #"{"v":2,"n":"m","u":"r","e":["h.local"],"seed":"moved","h":"SHA256:a","p":"/bin/herdr"}"#
        let url = "bleat://pair?d=" + PairingPayload.base64URLEncode(Data(v2.utf8))
        #expect(throws: PairingError.unsupportedVersion(2)) {
            try PairingPayload(urlString: url)
        }
    }

    /// A v2 code that dropped every field but the version must still be
    /// identifiable as a version problem.
    @Test("a newer format carrying nothing else still reports the version")
    func unsupportedVersionFromBareProbe() {
        let url = "bleat://pair?d=" + PairingPayload.base64URLEncode(Data(#"{"v":7}"#.utf8))
        #expect(throws: PairingError.unsupportedVersion(7)) {
            try PairingPayload(urlString: url)
        }
    }

    /// The QR carries the key's wire blob and nothing else — the algorithm is
    /// the blob's own first field, so the text prefix would be 12 characters of
    /// repetition. What comes back out is the exact OpenSSH string the pin is
    /// compared against.
    @Test("the host key travels as a blob and rebuilds its OpenSSH form")
    func hostKeyRebuilds() throws {
        let decoded = try PairingPayload(urlString: try sample().urlString())
        #expect(decoded.hostKey == Self.hostKey)
        #expect(decoded.hostKey.hasPrefix("ssh-ed25519 "))
        // And the prefix really is absent from the wire.
        let encoded = try String(data: JSONEncoder().encode(sample()), encoding: .utf8)
        #expect(try #require(encoded).contains("ssh-ed25519") == false)
    }

    /// A host key that will not parse could never be pinned, so a payload
    /// carrying one is malformed rather than merely odd.
    @Test("an unparseable host key is rejected")
    func badHostKeyRejected() throws {
        var json = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(sample())) as! [String: Any]
        json["h"] = "not-a-key"
        let data = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: PairingError.malformedPairingCode) {
            try PairingPayload(urlString: "bleat://pair?d=" + PairingPayload.base64URLEncode(data))
        }
    }

    @Test("a seed that is not 32 bytes is malformed")
    func badSeedLength() throws {
        var json = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(sample())) as! [String: Any]
        json["k"] = PairingPayload.base64URLEncode(Data(repeating: 1, count: 16))
        let data = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: PairingError.malformedPairingCode) {
            try PairingPayload(urlString: "bleat://pair?d=" + PairingPayload.base64URLEncode(data))
        }
    }

    @Test("an endpoint that will not parse fails the whole payload")
    func badEndpoint() throws {
        var json = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(sample())) as! [String: Any]
        json["e"] = ["rawillkair.local", "herdr.dev:99999"]
        let data = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: PairingError.malformedPairingCode) {
            try PairingPayload(urlString: "bleat://pair?d=" + PairingPayload.base64URLEncode(data))
        }
    }
}
