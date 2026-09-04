import Crypto
import Foundation
import Testing
@testable import BleatKit

@Suite("Pairing payload")
struct PairingPayloadTests {

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
            hostKeyFingerprint: "SHA256:5kgLcSfLx2/OaEHRcfc7PhrQ2uLNlTc8aL19AfjYn78",
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
            hostKeyFingerprint: "SHA256:x", herdrPath: "/bin/herdr"
        )
        let decoded = try PairingPayload(urlString: try payload.urlString())
        #expect(try decoded.enrollmentKey().fingerprint == pair.fingerprint)
    }

    /// Every byte in the QR is modules, and modules decide whether it scans at
    /// arm's length. A raw seed is ~44 base64 characters where an OpenSSH PEM
    /// would be ~600, and this asserts that budget rather than trusting it.
    ///
    /// The threshold is a QR version, not a round number. Measured against
    /// `CIQRCodeGenerator` at correction level M: 403 bytes produces version
    /// 12, 500 produces 14, 600 produces 15. The four-endpoint sample below is
    /// about as large as a real host gets, so capping at 512 keeps a realistic
    /// payload at version 14 or under — still comfortable to scan across a
    /// desk. Blowing this budget means the format grew; re-measure before
    /// raising it.
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
