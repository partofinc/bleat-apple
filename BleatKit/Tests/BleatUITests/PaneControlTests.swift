import BleatKit
import Testing
@testable import BleatUI

/// Input ownership, which is the one thing on this screen that reaches out and
/// changes someone else's machine.
///
/// Herdr allows one input owner per pane, and there is no gentle version of
/// becoming it: measured 8 Sept 2026 against a pane another client held, a
/// `terminal session control` client **without** `--takeover` received no
/// frames and landed no input, silently — while the same client with
/// `--takeover` moved the program's viewport from rows 1–29 to 30–58. So every
/// path into `.controlling` is a path that takes an agent away from whoever is
/// using it, and each one is guarded here.
@Suite("Taking a pane's input")
@MainActor
struct PaneControlTests {

    @Test("a pane is read-only until something asks otherwise")
    func observingByDefault() {
        #expect(PaneModel(previewing: .live).control == .observing)
    }

    /// **The guard that matters most.** `takeControl` seizes the pane, and a
    /// model with no viewport has not been laid out — there is no size to open
    /// a stream at, so taking input here would be a seizure that buys nothing
    /// and might never be released, because nothing is on screen to release it.
    @Test("control cannot be taken before the terminal has a size")
    func takingNeedsAViewport() {
        let model = PaneModel(previewing: .live)
        model.takeControl()
        #expect(model.control == .observing, "a pane was seized before it had been laid out")
    }

    /// Sending is gated on owning, not on having a stream. A key that escaped
    /// while observing would be input on a pane this screen explicitly does not
    /// hold — the exact thing `observe` exists to make impossible.
    @Test("keys are not sent while observing")
    func sendingIsInert() async {
        let model = PaneModel(previewing: .live)
        await model.send(.pageUp)
        await model.send(.pageDown)
        #expect(model.control == .observing)
        #expect(model.phase == .live, "sending disturbed a pane that was only being watched")
    }

    /// Releasing what was never taken must not reopen the stream, which is what
    /// `start()` would do — on a preview model that is inert, and on a real one
    /// it would tear down a working `observe` for nothing.
    @Test("releasing while observing does nothing")
    func releasingIsInert() async {
        let model = PaneModel(previewing: .live)
        await model.releaseControl()
        #expect(model.control == .observing)
        #expect(model.phase == .live)
    }

    /// The state the toolbar and the scroll keys both key off. A seeded model
    /// is the only way to reach it without a host.
    @Test("a seeded controlling model reports that it holds the pane")
    func seededControl() {
        #expect(PaneModel(previewing: .live, control: .controlling).control == .controlling)
    }
}
