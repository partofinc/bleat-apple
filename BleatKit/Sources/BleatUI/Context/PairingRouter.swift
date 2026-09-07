import BleatKit
import Observation

/// Whether the pairing sheet is up, and what it should start with.
///
/// A router rather than a screen's `@State` because pairing can now begin in
/// two places that are not the same screen: the button on the peer list, and a
/// `bleat://pair?d=…` link the system hands the app. The link can arrive while
/// the user is three screens deep in a host, so the presentation has to live
/// above the navigation stack — the same reason `UnpairModel` does.
@Observable
public final class PairingRouter {
    public var isPresented = false
    /// A link to redeem as soon as the sheet appears. `nil` means the user
    /// opened it themselves and the camera should just come up.
    public private(set) var incomingCode: String?

    public init() {}

    /// The toolbar button and the empty state.
    public func open() {
        guard !isPresented else { return }
        incomingCode = nil
        isPresented = true
    }

    /// A `bleat://` URL, from the system camera or anywhere else that can open
    /// one.
    ///
    /// **Accepted even when the sheet is already up**, and handed to it rather
    /// than dropped. This used to refuse, on the reasoning that the sheet's own
    /// camera covers that case — which is false once the sheet is showing a
    /// failure or a result, where there is no viewfinder. A pairing that failed
    /// and then ignored the user going back to the system camera to scan again
    /// was a dead end that looked like a broken app.
    ///
    /// Safety comes from the reader, not from here: `PairingModel` takes a code
    /// only from an idle phase, so a redemption in flight — holding a
    /// single-use enrollment key it is part way through spending — is never
    /// raced.
    ///
    /// Codes that are not addressed to Bleat are dropped without opening
    /// anything. The app is registered for one scheme, so this should not
    /// happen — but "should not" is not a reason to raise a pairing sheet over
    /// whatever the user was doing.
    @discardableResult
    public func open(code: String) -> Bool {
        guard PairingPayload.looksLikeAPairingCode(code) else { return false }
        incomingCode = code
        isPresented = true
        return true
    }

    /// Called by the sheet once it has taken the code.
    ///
    /// Separate from reading it because the read happens in a view body and the
    /// clear must not: mutating observable state during a view update is
    /// undefined, and SwiftUI may evaluate a sheet's content in a pass it then
    /// discards — which would consume the link and present an empty scanner.
    public func clearIncomingCode() {
        incomingCode = nil
    }
}
