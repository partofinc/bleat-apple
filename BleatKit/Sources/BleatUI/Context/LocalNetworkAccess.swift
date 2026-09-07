import Foundation
import Network
import Observation

/// Whether iOS is letting this app reach the local network yet.
///
/// **This exists because the first pairing on a fresh install always failed.**
/// Herdr is on a Mac at a `.local` name or a LAN address, and iOS gates both
/// behind a permission prompt that appears the moment something first tries.
/// The attempt that raises the alert does not wait for the answer — every
/// endpoint in the race fails while it is still on screen — so pairing
/// reported "none of N address(es) could be reached", which is precisely the
/// message this codebase elsewhere refuses to show for a host that was never
/// dialled. The user granted permission, saw a network error, and had to know
/// to tap "Try again".
///
/// Lives in `BleatUI` for the reason `Reachability` does: `Network` is
/// Apple-only, and `BleatKit` compiles for Linux.
///
/// **There is no API that answers this question directly**, so it is inferred
/// from an `NWBrowser` — the same permission gates Bonjour. `.ready` means the
/// browser is running, which it cannot do without access; a `.waiting` carrying
/// a policy-denied DNS error means the system is refusing, which covers both
/// "the alert is on screen, unanswered" and "the user said no". Anything else
/// stays `.unknown`, because blaming a permission for an unrelated failure
/// would send the user to Settings to fix something that is not broken.
@Observable
public final class LocalNetworkAccess {
    public enum State: Equatable {
        /// Nothing has asked yet, or the browser failed for its own reasons.
        case unknown
        /// Positively observed: the system is refusing local networking. Either
        /// the alert is up and unanswered, or the answer was no.
        case blocked
        case allowed
    }

    public private(set) var state: State = .unknown
    public var isAllowed: Bool { state == .allowed }

    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "team.partof.bleat.local-network")

    public init() {}

    /// Start asking, which is what raises the system alert.
    ///
    /// Called when the pairing sheet appears rather than at launch. That is the
    /// whole point: the alert then arrives while the user is still lining the
    /// camera up, so it is answered before there is a code to redeem — and it
    /// arrives attached to an action that obviously needs the network, instead
    /// of on a cold first launch with no context.
    ///
    /// Idempotent. The browser is kept running afterwards, because a grant is
    /// only observable while something is watching.
    public func prime() {
        guard browser == nil else { return }
        let parameters = NWParameters()
        // Nothing here is peer-to-peer; asking for it would widen the
        // permission the alert describes for no gain.
        parameters.includePeerToPeer = false
        let browser = NWBrowser(
            for: .bonjour(type: Self.serviceType, domain: nil),
            using: parameters
        )
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in self?.apply(state) }
        }
        self.browser = browser
        browser.start(queue: queue)
    }

    /// Wait for permission, up to `seconds`, and report whether it arrived.
    ///
    /// Polled rather than built on a continuation. A continuation would have to
    /// be resumed from both the state handler and a timeout, and the failure
    /// mode of getting that wrong is a task that never resumes — a pairing
    /// sheet stuck on a spinner with the host's enrollment window ticking down.
    /// A quarter-second poll against an already-published property costs
    /// nothing and cannot leak.
    public func allowed(within seconds: Double) async -> Bool {
        prime()
        let deadline = Date().addingTimeInterval(seconds)
        while !isAllowed, Date() < deadline {
            do { try await Task.sleep(for: .milliseconds(250)) } catch { break }
        }
        return isAllowed
    }

    /// `_ssh._tcp`, because that is honestly what the app connects to. The
    /// declaration in `Support/Info.plist` has to match this string or the
    /// browser is refused before the permission is ever consulted.
    static let serviceType = "_ssh._tcp"

    private func apply(_ state: NWBrowser.State) {
        switch state {
        case .ready:
            self.state = .allowed
        case .waiting(let error), .failed(let error):
            if Self.isPermissionRefusal(error) { self.state = .blocked }
        case .setup, .cancelled:
            break
        @unknown default:
            break
        }
    }

    /// The two `DNSServiceErrorType` codes mDNSResponder returns when the local
    /// network permission is not granted. Written as literals rather than the
    /// `dnssd` constants so this file needs no extra import for two numbers:
    /// `kDNSServiceErr_NoAuth` and `kDNSServiceErr_PolicyDenied`.
    private static func isPermissionRefusal(_ error: NWError) -> Bool {
        guard case .dns(let code) = error else { return false }
        return code == -65555 || code == -65570
    }
}
