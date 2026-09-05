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
        case pairing
        case paired(PairedPeer)
        /// Carries a message already fit to show: every `PairingError` case
        /// describes itself.
        case failed(String)
    }

    private(set) var phase: Phase = .waiting
    /// The link, when the user pastes one instead of scanning.
    var typedCode = ""

    private let store: PeerStore
    /// Codes already tried, so the camera reporting one sixty times a second
    /// produces one attempt — and a code that failed is not retried on the very
    /// next frame while the user is still pointing at it.
    private var attempted: Set<String> = []

    init(store: PeerStore) {
        self.store = store
    }

    /// Whether a scanned code should be acted on at all.
    ///
    /// Nothing is attempted while a pairing is in flight: the enrollment key is
    /// single-use, and two overlapping redemptions would race to install and
    /// then delete it.
    func shouldAttempt(_ code: String) -> Bool {
        phase == .waiting && !attempted.contains(code)
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

    func retry() {
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
        attempted.insert(code)
        do {
            phase = .paired(try await store.pair(withCode: code))
        } catch {
            phase = .failed(String(describing: error))
        }
    }
}
