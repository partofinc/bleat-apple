import BleatKit
import Testing
@testable import BleatUI

/// The field that starts a session, above the transport.
///
/// `SessionLaunchTests` covers what is sent; this covers what the screen
/// decides before anything is sent — which is most of the value, because
/// `herdr session attach` is idempotent and so cannot tell the caller that the
/// session was already somebody else's.
@Suite("Naming a new session")
@MainActor
struct NewSessionTests {

    @Test("an empty field is the resting state, not an error")
    func emptyIsQuiet() {
        let model = NewSessionModel(previewing: "")
        #expect(model.nameProblem == nil, "an untouched field was already complaining")
        #expect(!model.canStart)
    }

    @Test("a name herdr would refuse is refused here, with the reason")
    func badNameIsExplained() {
        let model = NewSessionModel(previewing: "my session")
        #expect(model.nameProblem != nil)
        #expect(!model.canStart)
    }

    @Test("a usable name arms the button")
    func goodNameIsAllowed() {
        let model = NewSessionModel(previewing: "scratch")
        #expect(model.nameProblem == nil)
        #expect(model.canStart)
    }

    /// **The launch *is* idempotent, which is why this matters.** `herdr
    /// session attach` against a running session succeeds silently — same pid,
    /// no error, no second server — so nothing downstream can tell that the
    /// name was already somebody's. The list already on screen is both the
    /// faster answer and the only way to say so *before* the tap.
    @Test("a running session of that name is recognised from the list on screen")
    func spotsARunningSession() {
        let model = NewSessionModel(previewing: "work")
        #expect(model.existing(in: SessionInfo.samples)?.running == true)
    }

    /// Measured against herdr 0.9.0: a stopped session keeps its session
    /// directory, and the same command that creates one *resumes* it — with
    /// whatever workspaces it had. Not a failure, but not what "new session"
    /// implies either, so the field says so.
    @Test("a stopped session of that name would be resumed, not created")
    func spotsAStoppedSession() {
        let model = NewSessionModel(previewing: "bleat-test")
        #expect(model.existing(in: SessionInfo.samples)?.running == false)
    }

    @Test("a free name matches nothing")
    func freeName() {
        #expect(NewSessionModel(previewing: "scratch").existing(in: SessionInfo.samples) == nil)
    }

    /// An invalid name must not be matched against the host's list either — it
    /// can never be started, so reporting it as "already running" would be a
    /// second, wrong explanation on top of the right one.
    @Test("an unusable name matches nothing, whatever the host has")
    func invalidNameMatchesNothing() {
        #expect(NewSessionModel(previewing: "work ").existing(in: SessionInfo.samples) == nil)
    }

    /// The `#Preview` seam, the same promise `RemoteList(previewing:)` makes —
    /// and it matters more here, because this one writes. A canvas that dialled
    /// would start a session on the dev Mac.
    @Test("a parked model launches nothing")
    func parkedLaunchesNothing() async {
        let model = NewSessionModel(previewing: "scratch")
        #expect(await model.start(on: .preview) == false)
        #expect(model.failure == nil)
        #expect(!model.isStarting)
    }

    /// A failure is about the attempt that produced it. Left standing while the
    /// user edits the name, it reads as a verdict on the new one.
    @Test("editing the name is not still an error")
    func failureIsClearable() {
        let model = NewSessionModel(previewing: "work", failure: "herdr server is already running")
        #expect(model.failure != nil)
        model.clearFailure()
        #expect(model.failure == nil)
    }
}
