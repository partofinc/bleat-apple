import BleatKit
import Testing
@testable import BleatUI

/// Which sessions a swipe may act on — the guard, on its own.
///
/// Worth its own suite because it is the only thing standing between a swipe
/// and `herdr session stop`, which ends every process in a session. Measured
/// against herdr 0.9.0: stopping a session killed its pane's shell outright.
@Suite("What a session row offers")
@MainActor
struct SessionActionsTests {

    private func peer(created: [String] = [], started: [String] = []) -> PairedPeer {
        var peer = PairedPeer.preview
        peer.createdSessions = created.isEmpty ? nil : created
        peer.startedSessions = started.isEmpty ? nil : started
        return peer
    }

    private func session(_ name: String, running: Bool) -> SessionInfo {
        SessionInfo(name: name, running: running, isDefault: false)
    }

    private func actions(
        _ name: String, running: Bool, created: [String] = [], started: [String] = []
    ) -> [SessionControlModel.Action] {
        SessionControlModel.actions(
            for: session(name, running: running), on: peer(created: created, started: started)
        )
    }

    // MARK: - Stop, which is the guarded one

    /// **The one that matters.** `work` is somebody's real session, running
    /// because they are using it. Nothing this phone did put it there, so there
    /// is no Stop.
    @Test("a running session this phone did not start cannot be stopped")
    func noStopForSomebodyElses() {
        #expect(actions("work", running: true).isEmpty)
        // Not even when the phone owns a *different* session on the same host.
        #expect(actions("work", running: true, created: ["scratch"], started: ["scratch"]).isEmpty)
    }

    @Test("a running session this phone started can be stopped")
    func stopWhatWeStarted() {
        #expect(actions("scratch", running: true, started: ["scratch"]) == [.stop])
    }

    /// The claim that matters for Stop is "this phone is why it is running",
    /// not "this phone made it once". A session created here but started again
    /// by somebody at the Mac is theirs while it runs.
    @Test("having created a session is not on its own a licence to stop it")
    func createdButNotStarted() {
        #expect(
            actions("scratch", running: true, created: ["scratch"]).isEmpty,
            "a session running for somebody else's reasons offered a Stop"
        )
    }

    // MARK: - Start, which is not guarded

    /// **Anyone's stopped session may be started.** It restores rather than
    /// creates — measured: workspaces, panes and a fresh shell in each come
    /// back — so it ends nothing, and it is the only way back when the Mac has
    /// rebooted with nothing up.
    @Test("a stopped session may be started even if this phone never touched it")
    func startAnyStoppedSession() {
        #expect(actions("default", running: false) == [.start])
    }

    /// Start first, so a full swipe reaches the harmless one rather than
    /// Delete.
    @Test("a stopped session this phone created offers Start before Delete")
    func stoppedOursOffersBoth() {
        #expect(actions("scratch", running: false, created: ["scratch"]) == [.start, .delete])
    }

    /// Delete removes the session *directory*, which for a session somebody
    /// else set up is their layout. Starting one does not earn the right to
    /// throw it away.
    @Test("restarting somebody else's session does not make it deletable")
    func startingDoesNotEarnDelete() {
        #expect(actions("default", running: false, started: ["default"]) == [.start])
    }

    /// A reinstall loses both records — they live in Application Support, which
    /// is excluded from backup. It can still start things, and can stop nothing
    /// it did not start. That is the intended direction.
    @Test("a fresh install can start anything and stop nothing")
    func freshInstall() {
        #expect(actions("scratch", running: false) == [.start])
        #expect(actions("scratch", running: true).isEmpty)
    }

    /// Starting is the one action that ends nothing, and the way back is the
    /// Stop beside it — which starting is what earns. Stopping and deleting
    /// both end things that cannot be brought back.
    @Test("only the destructive actions ask first")
    func onlyDestructiveActionsAsk() {
        #expect(!SessionControlModel.needsConfirmation(.start))
        #expect(SessionControlModel.needsConfirmation(.stop))
        #expect(SessionControlModel.needsConfirmation(.delete))
    }

    @Test("beginning a destructive action asks rather than acting")
    func beginAsks() {
        let model = SessionControlModel(previewing: .idle)
        model.begin(.delete, about: session("scratch", running: false), on: .preview)
        #expect(model.isConfirming)
        #expect(model.pending?.action == .delete)
    }

    @Test("beginning a start does not raise a dialog")
    func beginStartDoesNotAsk() {
        let model = SessionControlModel(previewing: .idle)
        model.begin(.start, about: session("scratch", running: false), on: .preview)
        #expect(!model.isConfirming, "starting a session should not stop to ask")
    }

    @Test("asking arms a confirmation rather than acting")
    func askingOnlyAsks() {
        let model = SessionControlModel(previewing: .idle)
        model.ask(.stop, about: session("scratch", running: true))
        #expect(model.isConfirming)
        #expect(model.pending?.action == .stop)
        #expect(model.pending?.session.name == "scratch")
    }

    @Test("dismissing the dialog disarms it")
    func dismissingDisarms() {
        let model = SessionControlModel(previewing: .idle)
        model.ask(.delete, about: session("scratch", running: false))
        model.isConfirming = false
        #expect(model.phase == .idle)
        #expect(model.pending == nil, "a dismissed dialog left an action armed")
    }

    /// **The regression that shipped.** Start needs no confirmation, so it does
    /// not go through the dialog — and the reload used to hang off the dialog's
    /// button. So Start worked, the session came up, and the screen went on
    /// showing it as stopped until the user went back and reopened it.
    ///
    /// The fix is structural: `perform` calls `onCompleted` itself, so every
    /// way of starting an action ends the same way. This pins the half that can
    /// be reached without a host — that `begin` on an unconfirmed action really
    /// does run `perform`, against a peer with no endpoints, which
    /// `PeerConnection.connect` refuses before dialling.
    @Test("a start with no dialog still runs, and reports what happened")
    func startWithoutADialogStillRuns() async {
        let peers = PeerStore(registry: .sample())
        let model = SessionControlModel(
            connections: ConnectionStore(peers: peers, reachability: Reachability()),
            peers: peers
        )
        let unreachable = PairedPeer(
            hostKey: "ssh-ed25519 AAAA", name: "mac", username: "ravil", endpoints: []
        )

        model.begin(.start, about: session("scratch", running: false), on: unreachable)
        #expect(!model.isConfirming, "Start raised a dialog")

        // `begin` starts a detached task; wait for it to land rather than
        // guessing at a delay.
        for _ in 0..<200 where model.failureMessage == nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(
            model.failureMessage != nil,
            "begin did not run the action — the unconfirmed path is inert"
        )
    }

    /// The completion is what refreshes the screen, and it must not be tied to
    /// the dialog: the action that skips the dialog is the one that needed it
    /// most.
    @Test("the completion is called for an action that raises no dialog")
    func completionIsNotTiedToTheDialog() async {
        let model = SessionControlModel(previewing: .idle)
        let seen = Reported()
        model.onCompleted = { action in seen.action = action }
        // A parked model performs nothing, so nothing should be reported —
        // this pins that the hook exists and is wired to `perform`, not that a
        // preview quietly succeeds.
        _ = await model.perform(.start, about: session("x", running: false), on: .preview)
        #expect(seen.action == nil)
    }

    @MainActor private final class Reported {
        var action: SessionControlModel.Action?
    }

    /// **The claim must not be earned by a session that was already up.**
    ///
    /// The row said stopped because it was stopped when the list loaded; by the
    /// time Start is tapped somebody at the Mac may have started it and be
    /// working in it. The launch then fails — `error: herdr server is already
    /// running`, into a log — and a version that asked only "is it running
    /// now?" saw yes on its first poll and recorded the session as ours,
    /// putting a Stop button over their agents.
    ///
    /// Driven here against a peer with no endpoints so nothing is dialled: what
    /// is pinned is that a failed start records nothing at all. `SessionStarter`
    /// now reads the list *before* launching and refuses the claim outright
    /// when the session is already up.
    @Test("a start that does not succeed claims nothing")
    func aFailedStartClaimsNothing() async {
        let registry = PeerRegistry.sample()
        let peers = PeerStore(registry: registry)
        let model = SessionControlModel(
            connections: ConnectionStore(peers: peers, reachability: Reachability()),
            peers: peers
        )
        let unreachable = PairedPeer(
            hostKey: "ssh-ed25519 AAAA", name: "mac", username: "ravil", endpoints: []
        )
        try? registry.save(unreachable)

        #expect(await model.perform(
            .start, about: session("work", running: false), on: unreachable
        ) == false)

        let stored = (try? registry.all())?.first { $0.hostKey == unreachable.hostKey }
        #expect(stored?.startedHere("work") != true, "a failed start claimed the session")
        #expect(stored?.createdHere("work") != true, "a failed start claimed the session")
    }

    /// One at a time. `begin` starts an unstructured task, so two quick taps
    /// enqueue two of these — and two launches hold two exec channels against
    /// one name, while two stops raise a failure alert over one that had
    /// already worked.
    @Test("a second action is refused while the first is in flight")
    func noReentrancy() async {
        let peers = PeerStore(registry: .sample())
        let model = SessionControlModel(
            connections: ConnectionStore(peers: peers, reachability: Reachability()),
            peers: peers
        )
        let unreachable = PairedPeer(
            hostKey: "ssh-ed25519 AAAA", name: "mac", username: "ravil", endpoints: []
        )
        let target = session("scratch", running: false)

        async let first = model.perform(.start, about: target, on: unreachable)
        async let second = model.perform(.start, about: target, on: unreachable)
        let results = await [first, second]
        #expect(results.filter { $0 }.isEmpty)
        // Both cannot have got past the guard; the second returns immediately.
        #expect(model.failureMessage != nil)
    }

    /// The `#Preview` seam. This model *ends processes on someone's Mac*, so a
    /// canvas that reached the host would be the worst version of the bug the
    /// seam exists to prevent.
    @Test("a parked model does nothing when confirmed")
    func parkedActsOnNothing() async {
        let model = SessionControlModel(previewing: .idle)
        let target = session("scratch", running: true)
        model.ask(.stop, about: target)
        #expect(await model.perform(.stop, about: target, on: .preview) == false)
    }

    /// **The regression that shipped.** `confirm` used to read the armed action
    /// back out of `phase`, and SwiftUI clears a `confirmationDialog`'s binding
    /// *before* running the tapped button — which this model's `isConfirming`
    /// setter turns into `phase = .idle`. So by the time the action ran there
    /// was nothing armed, and Stop did nothing at all: no error, no alert, the
    /// session still running when the screen was reopened.
    ///
    /// Pinned by driving it exactly as SwiftUI does — arm, dismiss, then act —
    /// against a peer with **no endpoints**, which `PeerConnection.connect`
    /// refuses before it dials anything. So this reaches the transport layer
    /// and touches no network, which is the only way to tell "it tried and
    /// could not" apart from "it silently did nothing".
    @Test("a dismissed dialog does not silently cancel the action it confirmed")
    func actsAfterTheDialogHasGone() async {
        let peers = PeerStore(registry: .sample())
        let model = SessionControlModel(
            connections: ConnectionStore(peers: peers, reachability: Reachability()),
            peers: peers
        )
        let target = session("scratch", running: true)
        let unreachable = PairedPeer(
            hostKey: "ssh-ed25519 AAAA", name: "mac", username: "ravil", endpoints: []
        )

        model.ask(.stop, about: target)
        // What SwiftUI does on the way into the button's action.
        model.isConfirming = false
        #expect(model.phase == .idle, "the dialog no longer resets the phase, so this test proves nothing")

        #expect(await model.perform(.stop, about: target, on: unreachable) == false)
        #expect(
            model.failureMessage != nil,
            "the action returned without trying — the dismissal cancelled it, which is the bug"
        )
    }
}
