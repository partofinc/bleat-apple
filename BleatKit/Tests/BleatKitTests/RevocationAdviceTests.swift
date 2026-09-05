import Foundation
import Testing
@testable import BleatKit

@Suite("What to tell a user who has to revoke by hand")
struct RevocationAdviceTests {

    /// The marker makes this one command the user can copy, which is the whole
    /// reason `PairedPeer` stores it.
    @Test("a known marker becomes a command that names the line")
    func namesTheLine() {
        let marker = AuthorizedKeys.deviceMarker()
        let advice = RevocationAdvice.revoke(deviceMarker: marker.value, deviceFingerprint: "SHA256:abc")
        #expect(advice.command == "bleat keys revoke \(marker.value)")
        #expect(advice.detail == nil)
    }

    /// A record made before the marker was stored. The fingerprint is the same
    /// on every host and is what `bleat keys list` prints, so matching by eye
    /// is a check the user can actually perform.
    @Test("without a marker, the user is sent to the listing with a fingerprint")
    func fallsBackToTheFingerprint() {
        let advice = RevocationAdvice.revoke(deviceMarker: nil, deviceFingerprint: "SHA256:abc")
        #expect(advice.command == "bleat keys list")
        #expect(advice.detail?.contains("SHA256:abc") == true)
    }

    /// The marker comes off a JSON file on the device and is interpolated into
    /// a command the user pastes into a shell. `bleat keys revoke` would refuse
    /// anything malformed, so offering it here would send the user to run a
    /// command that fails — after which they have no reason to believe the key
    /// is still on the host. Both ends apply the same check.
    @Test("a marker the tool would refuse is not offered")
    func refusesAMarkerTheToolWouldReject() {
        for bad in ["", "bleat-device-", "not-a-marker", "bleat-device-a b", "bleat-device-x; rm -rf ~"] {
            let advice = RevocationAdvice.revoke(deviceMarker: bad, deviceFingerprint: "SHA256:abc")
            #expect(advice.command == "bleat keys list", "\(bad.debugDescription)")
        }
    }

    /// Reading the device key is one of the ways this screen is reached at all,
    /// so the advice cannot depend on having it.
    @Test("no marker and no fingerprint still says something actionable")
    func worksWithNeither() {
        let advice = RevocationAdvice.revoke(deviceMarker: nil, deviceFingerprint: nil)
        #expect(advice.command == "bleat keys list")
        #expect(advice.detail?.isEmpty == false)
    }

    /// The command has to be the one the tool accepts, not a plausible-looking
    /// one. Parsed back through the tool's own argument check.
    @Test("the suggested command parses as the tool would parse it")
    func theSuggestionIsValid() throws {
        let marker = AuthorizedKeys.deviceMarker()
        let advice = RevocationAdvice.revoke(deviceMarker: marker.value, deviceFingerprint: nil)
        let argument = try #require(advice.command.split(separator: " ").last)
        #expect(AuthorizedKeys.Marker(text: String(argument)) == marker)
    }
}
