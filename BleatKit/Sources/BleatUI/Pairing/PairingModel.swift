import BleatKit
import Foundation
import Observation

/// Drives the pairing sheet.
///
/// The state lives here rather than in the view because two of the transitions
/// are not obvious from the outside. A camera reports the same code many times
/// a second, so submission has to be idempotent per code; and a code that is
/// not a Bleat code must leave the scanner running, since the user is holding a
/// phone at a screen and reopening the sheet to try again is a poor answer.
@Observable
final class PairingModel {
    enum Phase: Equatable {
        /// Camera up, or waiting for a link to be pasted.
        case waiting
        /// Host work is in flight: a key is being installed, proven, and
        /// another deleted. Abandoning this loses outcomes that matter.
        case pairing
        /// Waiting for the user to answer iOS's local network alert. A separate
        /// case rather than a label on `pairing`, because **nothing is in
        /// flight here** — no connection is open and the host has not been
        /// touched — so unlike `pairing` this one must stay dismissable.
        case awaitingPermission
        case paired(PairedPeer)
        /// Carries a message already fit to show: every `PairingError` case
        /// describes itself.
        case failed(String)
    }

    private(set) var phase: Phase = .waiting

    /// Whether the sheet must not be dismissed. Deliberately **not** true while
    /// waiting on the permission alert: that wait can last a minute, and
    /// trapping the user behind a spinner they cannot cancel — with no route to
    /// Settings — is worse than letting them out of a sheet that is holding
    /// nothing.
    var isPairing: Bool { phase == .pairing }

    /// Whether a spinner belongs on screen.
    var isBusy: Bool { phase == .pairing || phase == .awaitingPermission }

    /// The link, when the user pastes one instead of scanning.
    var typedCode = ""

    private let store: PeerStore
    private let localNetwork: LocalNetworkAccess
    /// Where links delivered by the system arrive. Read from here rather than
    /// captured at init so a code that lands *while the sheet is already open*
    /// is still picked up — a failed pairing used to be a dead end for anyone
    /// who went back to the system camera and scanned again.
    private let router: PairingRouter
    /// Codes already tried, so the camera reporting one sixty times a second
    /// produces one attempt — and a code that failed is not retried on the very
    /// next frame while the user is still pointing at it.
    private var attempted: Set<String> = []

    init(store: PeerStore, localNetwork: LocalNetworkAccess, router: PairingRouter) {
        self.store = store
        self.localNetwork = localNetwork
        self.router = router
    }

    /// Ask iOS for the local network up front, when the sheet appears.
    ///
    /// The alert then arrives while the user is still lining up the camera,
    /// which is the actual fix for the first pairing on a fresh install always
    /// failing: nothing is in flight to be destroyed by it, and the answer
    /// exists before there is a code to redeem.
    func primeLocalNetwork() {
        localNetwork.prime()
    }

    /// Redeem links the system delivers, for as long as the sheet is open.
    ///
    /// A loop rather than a one-shot read, for two reasons. The code is
    /// consumed **here**, in a task, instead of inside the sheet's `ViewBuilder`
    /// — mutating observable state during a view update is undefined, and
    /// SwiftUI may evaluate a sheet's content in a pass whose result it throws
    /// away, which would swallow the very link the user tapped. And a code that
    /// arrives while the sheet is already up is no longer dropped: after a
    /// failure the user's obvious move is to go back to the system camera and
    /// scan again, and that used to reach a sheet that ignored it.
    ///
    /// Only picked up from an idle phase. A pairing in flight holds a
    /// single-use enrollment key it is part way through redeeming, and a second
    /// redemption would race it; a finished one has already spent the key.
    func followIncomingCodes() async {
        while !Task.isCancelled {
            if canAcceptACode, let code = router.incomingCode {
                router.clearIncomingCode()
                // Shown in the field as well as redeemed, so a failure leaves
                // the user looking at the code that was actually tried rather
                // than at an empty box and an error.
                typedCode = code
                phase = .pairing
                await pair(with: code)
            }
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
        }
    }

    /// `.paired` is excluded as much as `.pairing`: the key is spent, and
    /// redeeming again would replace a success with a confusing failure.
    private var canAcceptACode: Bool {
        switch phase {
        case .waiting, .failed: true
        case .pairing, .awaitingPermission, .paired: false
        }
    }

    /// Whether a scanned code should be acted on at all.
    ///
    /// Three reasons not to, and they are different:
    ///
    /// - It is not a Bleat code. A camera sees whatever is in front of it, and
    ///   turning a Wi-Fi QR into "pairing failed" would bury the real errors
    ///   and take the viewfinder away while the user is still aiming.
    /// - It has been tried already, so the same QR held in frame for a second
    ///   produces one attempt rather than sixty.
    /// - A pairing is in flight. The enrollment key is single-use, and two
    ///   overlapping redemptions would race to install and then delete it.
    func shouldAttempt(_ code: String) -> Bool {
        phase == .waiting
            && PairingPayload.looksLikeAPairingCode(code)
            && !attempted.contains(code)
    }

    func scanned(_ code: String) async {
        guard claim(code) else { return }
        await pair(with: code)
    }

    /// The pasted-link path. Deliberately not filtered by `attempted`: an
    /// explicit tap is the user asking again, which is exactly the case where
    /// retrying is right.
    func submitTypedCode() async {
        let code = typedCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty, phase == .waiting else { return }
        phase = .pairing
        await pair(with: code)
    }

    /// Back to the viewfinder, and willing to read the same code again.
    ///
    /// Clearing `attempted` is the whole point: the failure the user is
    /// retrying is nearly always transient — the phone was on the wrong
    /// network, the host had not finished starting — and they will point the
    /// camera at the *same* QR. Without this, every frame of it is filtered out
    /// and the button does nothing at all.
    func retry() {
        attempted.removeAll()
        phase = .waiting
    }

    /// Takes ownership of a scanned code, synchronously.
    ///
    /// Checking and then marking in two steps would let two frames of the same
    /// QR both pass the check: the callback spawns a `Task` per frame, and an
    /// `await` between the two is a place another task can run. One
    /// non-suspending function closes that window, and the window matters —
    /// the enrollment key is single-use, so two redemptions would race to
    /// install and then delete it.
    private func claim(_ code: String) -> Bool {
        guard shouldAttempt(code) else { return false }
        attempted.insert(code)
        phase = .pairing
        return true
    }

    private func pair(with code: String) async {
        // Deliberately does not mark the code as attempted: `claim` already did
        // that for the scan path, and doing it here too would let a failed
        // *paste* block the camera from ever reading the same QR.
        do {
            phase = .paired(try await store.pair(withCode: code))
        } catch {
            await handle(error, forCode: code)
        }
    }

    /// A failed attempt, and the one case worth trying again by itself.
    ///
    /// iOS raises its local network alert on the *first* connection to a
    /// `.local` name or a LAN address, and does not hold that connection open
    /// while it waits for an answer — so on a fresh install every endpoint in
    /// the race fails, and the user is shown a network error for a permission
    /// question they have not answered yet. Granting it then fixes nothing
    /// visible; they have to know to tap "Try again".
    ///
    /// So: when the system is positively refusing the local network and the
    /// failure is one that a refusal would cause, wait for the answer and go
    /// again. Retrying is safe because the enrollment key is only *spent* by a
    /// completed swap — an attempt that never reached the host has consumed
    /// nothing, and the host holds the code open for five minutes.
    private func handle(_ error: any Error, forCode code: String) async {
        guard Self.mightBeLocalNetworkRefusal(error) else {
            phase = .failed(ErrorMessage.of(error))
            return
        }
        // The browser may not have answered yet. A link opened from the system
        // camera raises the sheet and redeems in the same breath, and a
        // policy-denied lookup fails immediately — so on a fresh install the
        // failure can land first, with `state` still `.unknown`. That is not
        // evidence of a refusal and must not be read as one, but neither is it
        // evidence against: give the first answer a moment to arrive.
        var access = localNetwork.state
        if access == .unknown { access = await localNetwork.settled(within: 2) }
        guard access == .blocked else {
            phase = .failed(ErrorMessage.of(error))
            return
        }
        phase = .awaitingPermission
        guard await localNetwork.allowed(within: Self.localNetworkGrantWindow) else {
            // Still refused. Say what is actually wrong: "no address answered"
            // would send the user to check a network that is working fine.
            phase = .failed(
                """
                Bleat could not reach your local network. iOS asks for that \
                permission the first time the app connects to a Mac on it. \
                Allow it when iOS asks, or turn it on in Settings › Privacy & \
                Security › Local Network, then pair again.
                """
            )
            return
        }
        // Once only: this path is entered from `blocked`, and permission is now
        // granted, so a second failure is a different problem and belongs on
        // screen rather than in another wait.
        do {
            phase = .paired(try await store.pair(withCode: code))
        } catch {
            phase = .failed(ErrorMessage.of(error))
        }
    }

    /// Comfortably inside the host's five-minute enrollment window, and long
    /// enough for someone to read an alert and decide.
    static let localNetworkGrantWindow: Double = 60

    /// Whether this failure is one a refused local network would produce.
    ///
    /// Only "nothing answered" qualifies. A host key mismatch or a refused key
    /// means a machine *was* reached, so permission is not the story and
    /// retrying would paper over the thing the user needs to see.
    /// `TransportError.overlayUnreachable` is excluded, and that is the point
    /// of it being its own case. Nothing local was dialled in that race — every
    /// candidate was a mesh VPN address — so the local network permission
    /// cannot be the cause, and treating it as one would make a user who had
    /// once denied that permission wait out the whole minute and then be told
    /// their local network is unreachable, for a failure that was about a
    /// tunnel.
    static func mightBeLocalNetworkRefusal(_ error: any Error) -> Bool {
        if case TransportError.connectionFailed = error { return true }
        return false
    }
}
