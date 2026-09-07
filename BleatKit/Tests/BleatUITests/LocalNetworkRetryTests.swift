import BleatKit
import Foundation
import Testing
@testable import BleatUI

/// Retrying a pairing once iOS answers its local network prompt.
///
/// The first pairing on a fresh install always failed: iOS raises the local
/// network alert on the first connection to a `.local` name or a LAN address
/// and does not hold that connection while it waits, so every endpoint in the
/// race failed and the user was shown "none of N address(es) could be reached"
/// for a question they had not answered. Granting it fixed nothing visible.
///
/// What is worth pinning here is the *rule*, not the plumbing: which failures
/// may be retried, and that permission is only blamed on positive evidence.
@Suite("Waiting on the local network prompt")
@MainActor
struct LocalNetworkRetryTests {

    /// "Nothing answered" is exactly what a refused local network looks like
    /// from inside the endpoint race, so it is the one failure worth waiting on.
    @Test("a failure to reach anything is retryable")
    func reachFailureIsRetryable() {
        #expect(PairingModel.mightBeLocalNetworkRefusal(
            TransportError.connectionFailed("none of 3 address(es) could be reached")
        ))
    }

    /// A machine answered, and it was the wrong one — or it refused the key.
    /// Both mean the network is fine, so waiting on a permission would hide the
    /// thing the user actually has to see, and a silent retry would repeat it.
    @Test("a host that answered is never retried as a permission problem")
    func answeredFailuresAreNotRetryable() {
        #expect(PairingModel.mightBeLocalNetworkRefusal(TransportError.hostKeyMismatch(
            expected: "ssh-ed25519 AAAA", actual: "ssh-ed25519 BBBB"
        )) == false)
        #expect(PairingModel.mightBeLocalNetworkRefusal(
            TransportError.authenticationFailed("the host refused every key")
        ) == false)
        #expect(PairingModel.mightBeLocalNetworkRefusal(
            PairingError.notAPairingCode
        ) == false)
    }

    /// The window has to sit inside the host's, or the wait outlives the code
    /// it is waiting to redeem. `bleat pair` holds the enrollment key open for
    /// five minutes and sshd expires it sixty seconds after that.
    @Test("the wait fits inside the host's enrollment window")
    func waitFitsTheEnrollmentWindow() {
        #expect(PairingModel.localNetworkGrantWindow > 0)
        #expect(PairingModel.localNetworkGrantWindow < 5 * 60)
    }

    /// Starting `.unknown` is what keeps a permission from being blamed for an
    /// unrelated failure: the retry path is entered only from `.blocked`, which
    /// is set only when the system says so in as many words.
    @Test("access starts unknown, so nothing is blamed on it by default")
    func startsUnknown() {
        let access = LocalNetworkAccess()
        #expect(access.state == .unknown)
        #expect(access.isAllowed == false)
    }

    /// Priming is what raises the alert, and the sheet does it on appear — so
    /// it must survive being called again when the sheet is reopened.
    @Test("priming twice is harmless")
    func primeIsIdempotent() {
        let access = LocalNetworkAccess()
        access.prime()
        access.prime()
        #expect(access.state != .allowed || access.isAllowed)
    }

    /// A zero-length wait must return rather than hang: the sheet is showing a
    /// spinner behind this, with the host's window ticking down.
    @Test("waiting returns even when permission never arrives")
    func waitTerminates() async {
        let access = LocalNetworkAccess()
        #expect(await access.allowed(within: 0) == false)
    }

    /// The service type is declared in `Support/Info.plist`, and NWBrowser is
    /// refused outright if the two disagree — before the permission is ever
    /// consulted, so the app would conclude "blocked" and never retry.
    @Test("the browsed service matches what the plist declares")
    func serviceTypeMatchesThePlist() {
        #expect(LocalNetworkAccess.serviceType == "_ssh._tcp")
    }
}
