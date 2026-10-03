import BleatKit
import Testing
@testable import BleatUI

/// Which sessions a swipe may act on, and what it asks before it acts.
///
/// Worth its own suite because between a swipe and `herdr session stop` — which
/// ends every process in a session; measured against herdr 0.9.0, it killed a
/// pane's shell outright — there is now only the confirmation. Stop used to be
/// gated on `startedHere` as well; it is not, so the wording is covered here
/// beside the actions.
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

    // MARK: - Stop, which is offered for anyone's session

    /// **The one that changed, and the case the feature is for.** `work` is
    /// somebody's real session, running because they are using it — and it can
    /// be stopped from the phone. Gating this on `startedHere` withheld Stop
    /// from every session started at the Mac and from every session a reinstall
    /// had forgotten, which is most of them.
    @Test("a running session this phone did not start can still be stopped")
    func stopAnybodysRunningSession() {
        #expect(actions("work", running: true) == [.stop])
        // Nor does owning a *different* session on the same host come into it.
        #expect(
            actions("work", running: true, created: ["scratch"], started: ["scratch"]) == [.stop]
        )
    }

    @Test("a running session this phone started can be stopped")
    func stopWhatWeStarted() {
        #expect(actions("scratch", running: true, started: ["scratch"]) == [.stop])
    }

    /// Stop is the *only* action a running session has, whoever started it:
    /// herdr refuses to delete one that is up, so offering Delete there would be
    /// an action that had already failed before it was taken.
    @Test("a running session is never offered Delete")
    func noDeleteWhileRunning() {
        #expect(
            actions("scratch", running: true, created: ["scratch"], started: ["scratch"]) == [.stop]
        )
        #expect(!actions("work", running: true).contains(.delete))
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
    /// is excluded from backup. It can still start and stop anything; what it
    /// cannot do is delete, and that is the line that matters. A stop has a
    /// Start beside it; a delete has nothing at all.
    @Test("a fresh install can start and stop anything, and delete nothing")
    func freshInstall() {
        #expect(actions("scratch", running: false) == [.start])
        #expect(actions("scratch", running: true) == [.stop])
    }

    /// **A name this app cannot send earns no actions**, and Stop being ungated
    /// is what made this reachable. herdr accepts `-x`; `SessionName` refuses
    /// it, because `herdr session stop -- -x` parses the name as a flag and can
    /// never address it. A row created at the Mac under such a name would
    /// otherwise swipe to a Stop whose only outcome is "not a name this app can
    /// act on".
    @Test("a session herdr accepted and this app cannot address offers nothing")
    func noActionsForANameWeCannotSend() {
        #expect(SessionName("-x") == nil, "the premise: this name is one we refuse")
        #expect(actions("-x", running: true).isEmpty)
        // Start was already reachable for any stopped session, so it is covered
        // by the same guard rather than needing its own.
        #expect(actions("-x", running: false).isEmpty)
        #expect(actions("-x", running: false, created: ["-x"]).isEmpty)
    }

    /// The names herdr and this app agree on are unaffected — the guard above
    /// must not be a filter that quietly eats ordinary rows.
    @Test("ordinary names are unaffected by the name check")
    func ordinaryNamesStillOffered() {
        for name in ["work", "bleat-test", "phone.2", "a_b"] {
            #expect(actions(name, running: true) == [.stop], "\(name) lost its Stop")
        }
    }

    // MARK: - What the confirmation says, which is the guard that is left

    /// **The sentence in front of `herdr session stop`.** With Stop offered for
    /// anyone's session, this is the only thing that tells the user they are
    /// about to end work that is not theirs — so it is pinned here rather than
    /// left inside a view modifier where nothing could read it.
    @Test("stopping a session this phone did not start says so")
    func stopConfirmationNamesWhoseSessionItIs() {
        let message = SessionControlModel.confirmation(
            for: .stop, about: session("work", running: true), on: peer()
        )
        #expect(message.contains("work"))
        #expect(message.contains("cannot be undone"))
        #expect(
            message.contains("did not start"),
            "nothing in the confirmation said the session is not this phone's to end"
        )
    }

    /// And it does not say it about a session the phone did start, which would
    /// be false — and a warning that is there every time is one to tap through
    /// on the occasion it is true.
    @Test("stopping our own session does not claim somebody may be working in it")
    func stopConfirmationIsQuietAboutOurOwn() {
        let message = SessionControlModel.confirmation(
            for: .stop, about: session("scratch", running: true), on: peer(started: ["scratch"])
        )
        #expect(message.contains("scratch"))
        #expect(!message.contains("did not start"))
    }

    /// Delete says what it removes, and says nothing about who started it: the
    /// claim that gates it has already answered that question.
    @Test("deleting names the session and its workspaces")
    func deleteConfirmation() {
        let message = SessionControlModel.confirmation(
            for: .delete, about: session("scratch", running: false), on: peer(created: ["scratch"])
        )
        #expect(message.contains("scratch"))
        #expect(message.contains("workspaces"))
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
        _ = try? registry.save(unreachable)

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
