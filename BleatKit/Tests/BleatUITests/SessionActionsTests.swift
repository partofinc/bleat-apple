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
    @Test("a stopped session this phone started can be deleted, and only deleted")
    func deleteWhenStopped() {
        #expect(SessionControlModel.actions(
            for: session("scratch", running: false), on: peer(created: ["scratch"])
        ) == [.delete])
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
        model.ask(.stop, about: session("scratch", running: true))
        #expect(await model.confirm(on: .preview) == false)
    }

    @Test("confirming with nothing armed does nothing")
    func nothingArmed() async {
        #expect(await SessionControlModel(previewing: .idle).confirm(on: .preview) == false)
    }
}
