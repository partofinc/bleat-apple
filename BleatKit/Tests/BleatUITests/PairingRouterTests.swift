import BleatKit
import Testing
@testable import BleatUI

/// Opening the pairing sheet from a `bleat://` link.
///
/// The scheme is registered on the app target, so the system camera can hand
/// Bleat a pairing code without the user opening the app and finding the
/// scanner first. What the app does with that URL is the part worth testing:
/// registering a scheme that leads nowhere is worse than not registering one,
/// because the QR then looks tappable and does nothing.
@Suite("Opening a pairing link")
@MainActor
struct PairingRouterTests {

    /// A real code's shape. The payload is not decoded here — the router only
    /// decides whether to raise the sheet, and `PairingPayload` owns the rest.
    private let code = "bleat://pair?d=AQIDBA"

    @Test("a pairing link raises the sheet and is handed to it once")
    func opensOnALink() {
        let router = PairingRouter()
        #expect(router.open(code: code))
        #expect(router.isPresented)
        #expect(router.takeIncomingCode() == code)
        // Consumed: the sheet's `task` runs again whenever the view is
        // re-attached, and the enrollment key is single-use — redeeming twice
        // reports a failure for a pairing that already succeeded.
        #expect(router.takeIncomingCode() == nil)
    }

    /// The app is registered for one scheme, so this should not arrive. "Should
    /// not" is not a reason to throw a pairing sheet over whatever the user was
    /// doing, and every other URL the OS could route here is someone else's.
    @Test("a URL that is not a pairing code opens nothing")
    func ignoresOtherURLs() {
        let router = PairingRouter()
        for other in ["https://herdr.dev", "bleat://something-else", "not a url at all", ""] {
            #expect(router.open(code: other) == false)
            #expect(router.isPresented == false)
        }
    }

    /// A pairing in flight is holding a single-use enrollment key it is part
    /// way through redeeming. A second code dropped into the same sheet would
    /// either race that redemption or discard work already done on the host.
    @Test("a link arriving while the sheet is up is refused, not queued")
    func refusesWhileOpen() {
        let router = PairingRouter()
        router.open()
        #expect(router.isPresented)
        #expect(router.open(code: code) == false)
        #expect(router.takeIncomingCode() == nil)
    }

    /// Opening by hand must not inherit a link from an earlier launch — the
    /// enrollment key behind it is long gone, so redeeming it would greet the
    /// user with a failure they did not ask for.
    @Test("opening from the button starts with no code")
    func buttonStartsClean() {
        let router = PairingRouter()
        #expect(router.open(code: code))
        router.isPresented = false
        router.open()
        #expect(router.isPresented)
        #expect(router.takeIncomingCode() == nil)
    }

    /// The plist and `BleatKit` have to agree on the scheme string, and no test
    /// can read the app target's `Info.plist` from here. This at least pins the
    /// value the QR is built from, so a change to it fails loudly next to the
    /// comment in `Support/Info.plist` that names the coupling.
    @Test("the registered scheme is the one the QR carries")
    func schemeMatchesTheQR() {
        #expect(PairingPayload.urlScheme == "bleat")
        #expect(PairingPayload.urlHost == "pair")
    }
}
