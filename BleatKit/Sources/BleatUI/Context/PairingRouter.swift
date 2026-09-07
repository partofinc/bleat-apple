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
    /// **Ignored when the sheet is already up**, and that is a refusal rather
    /// than an omission. A pairing in flight holds a single-use enrollment key
    /// that it is in the middle of redeeming; dropping a second code into the
    /// same sheet would either race that redemption or silently discard the
    /// work already done on the host. The sheet's own camera is running in the
    /// only other case, so the user has a way through either way.
    ///
    /// Codes that are not addressed to Bleat are dropped without opening
    /// anything. The app is registered for one scheme, so this should not
    /// happen — but "should not" is not a reason to raise a pairing sheet over
    /// whatever the user was doing.
    @discardableResult
    public func open(code: String) -> Bool {
        guard !isPresented, PairingPayload.looksLikeAPairingCode(code) else { return false }
        incomingCode = code
        isPresented = true
        return true
    }

    /// Cleared once the sheet has taken it, so dismissing and reopening by hand
    /// does not silently re-run a pairing whose enrollment key is long gone.
    public func takeIncomingCode() -> String? {
        defer { incomingCode = nil }
        return incomingCode
    }
}
