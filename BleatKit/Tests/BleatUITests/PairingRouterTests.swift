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

    @Test("a pairing link raises the sheet and is handed to it")
    func opensOnALink() {
        let router = PairingRouter()
        #expect(router.open(code: code))
        #expect(router.isPresented)
        #expect(router.incomingCode == code)
        // Consumed by the sheet, not by reading it: the read happens in a view
        // body and a mutation there is undefined.
        router.clearIncomingCode()
        #expect(router.incomingCode == nil)
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
            #expect(router.incomingCode == nil)
        }
    }

    /// A code arriving while the sheet is up is **kept**, not dropped. The old
    /// behaviour refused it on the grounds that the sheet's own camera covers
    /// that case — false once the sheet is showing a failure or a result, where
    /// there is no viewfinder, and a dead end that looks like a broken app.
    ///
    /// Safety lives in the reader: `PairingModel` takes a code only from an
    /// idle phase, so a redemption in flight is never raced.
    @Test("a link arriving while the sheet is up is kept for it")
    func keepsCodeWhileOpen() {
        let router = PairingRouter()
        router.open()
        #expect(router.incomingCode == nil)
        #expect(router.open(code: code))
        #expect(router.isPresented)
        #expect(router.incomingCode == code)
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
        #expect(router.incomingCode == nil)
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
