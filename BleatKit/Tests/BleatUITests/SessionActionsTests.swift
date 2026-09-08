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

    private func peer(created: [String]) -> PairedPeer {
        var peer = PairedPeer.preview
        peer.createdSessions = created.isEmpty ? nil : created
        return peer
    }

    private func session(_ name: String, running: Bool) -> SessionInfo {
        SessionInfo(name: name, running: running, isDefault: false)
    }

    /// **The one that matters.** `work` is somebody's real session; the phone
    /// did not start it, so there is nothing to swipe at all.
    @Test("a session this phone did not start offers nothing")
    func noActionsForSomebodyElses() {
        #expect(SessionControlModel.actions(
            for: session("work", running: true), on: peer(created: [])
        ).isEmpty)
        // Not even when the phone owns a *different* session on the same host.
        #expect(SessionControlModel.actions(
            for: session("work", running: true), on: peer(created: ["scratch"])
        ).isEmpty)
    }

    @Test("a running session this phone started can be stopped")
    func stopWhenRunning() {
        #expect(SessionControlModel.actions(
            for: session("scratch", running: true), on: peer(created: ["scratch"])
        ) == [.stop])
    }

    /// Never Stop *and* Delete: herdr refuses to delete a running session
    /// (`session_delete_failed`, "stop it before deleting"), so offering both
    /// would put an action on screen that has already failed before it is
    /// taken.
    @Test("a stopped session this phone started can be started again, or deleted")
    func stoppedOffersBoth() {
        #expect(SessionControlModel.actions(
            for: session("scratch", running: false), on: peer(created: ["scratch"])
        ) == [.start, .delete], "Start must come first, so a full swipe reaches the harmless one")
    }

    /// Starting is the one action that ends nothing, and the way back from an
    /// unwanted one is the Stop beside it — so it does not ask. Stopping and
    /// deleting both end things that cannot be brought back.
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

    /// A reinstall loses the record — it lives in Application Support, which is
    /// excluded from backup — and then offers nothing. That is the intended
    /// direction: the list is what this install remembers doing, not a claim
    /// the host would recognise.
    @Test("a fresh install claims nothing")
    func freshInstallClaimsNothing() {
        for running in [true, false] {
            #expect(SessionControlModel.actions(
                for: session("scratch", running: running), on: peer(created: [])
            ).isEmpty)
        }
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
