import BleatKit
import Testing
@testable import BleatUI

/// The form that starts an agent, above the transport.
///
/// `AgentStartTests` covers what is sent and what a failure means; this covers
/// what the screen decides before anything is sent — which matters more here
/// than anywhere else in the app, because this is the one write whose failure
/// is slow.
@Suite("Starting an agent from the phone")
@MainActor
struct NewAgentTests {

    private func freePanes() -> [Pane] { Pane.samples }

    @Test("an empty field is the resting state, not an error")
    func emptyIsQuiet() {
        let model = NewAgentModel(previewing: "")
        #expect(model.nameProblem == nil, "an untouched field was already complaining")
        #expect(!model.canStart)
    }

    /// herdr's own rule, brought forward so the user sees it while typing.
    @Test("a name herdr would refuse is refused here")
    func badNameIsExplained() {
        let model = NewAgentModel(previewing: "Reviewer", pane: "w2:p1", available: freePanes())
        #expect(model.nameProblem != nil)
        #expect(!model.canStart)
    }

    /// **A name and a pane, not just a name.** herdr answers
    /// `agent_pane_not_found` without one, and there is no sensible default —
    /// picking a pane for the user would start a program in a terminal they did
    /// not choose.
    @Test("a good name with no pane cannot start")
    func needsAPane() {
        let model = NewAgentModel(previewing: "reviewer", available: freePanes())
        #expect(model.nameProblem == nil)
        #expect(!model.canStart, "a start with no pane would be refused by the host")
    }

    @Test("a good name and a pane arm the button")
    func armed() {
        let model = NewAgentModel(previewing: "reviewer", pane: "w2:p1", available: freePanes())
        #expect(model.nameProblem == nil)
        #expect(model.canStart)
    }

    /// herdr refuses a duplicate with `agent_name_taken` — instantly, so this
    /// only saves a tap. It is the same tap that otherwise looks like the
    /// feature not working.
    @Test("a name already in use is refused here, with the reason")
    func duplicateNameIsExplained() {
        let model = NewAgentModel(
            previewing: "builder", pane: "w2:p1",
            available: freePanes(), takenNames: ["builder"]
        )
        #expect(model.nameProblem != nil)
        #expect(!model.canStart)
    }

    /// **The button is spent once something may be running.** A `warning`
    /// means herdr stopped waiting, which is not the same as nothing having
    /// happened — measured, the agent came up anyway with no name — and a
    /// retry would land on `agent_pane_busy` over it.
    @Test("a warning disarms the button rather than inviting a retry")
    func aWarningDisarms() {
        let model = NewAgentModel(
            previewing: "reviewer", pane: "w2:p1", available: freePanes(),
            warning: "claude is running in w2:p1, but it took longer than herdr waited."
        )
        #expect(!model.canStart)
    }

    /// Editing the name is not undoing a start. Only reopening the sheet is —
    /// the model is `@State` on the screen, so everything it holds outlives a
    /// dismissal.
    @Test("editing the name clears a failure but not a warning")
    func onlyResetClearsAWarning() {
        let model = NewAgentModel(
            previewing: "reviewer", pane: "w2:p1", available: freePanes(),
            failure: "zsh: command not found: devin",
            warning: "claude is running in w2:p1."
        )
        model.clearFailure()
        #expect(model.failure == nil)
        #expect(model.warning != nil, "a text edit cleared a warning about a running agent")

        model.reset()
        #expect(model.warning == nil)
        #expect(model.name.isEmpty)
        #expect(model.pane == nil, "a reopened sheet must not come up aimed at the old pane")
        #expect(model.kind == .claude)
        #expect(!model.canStart)
    }

    /// The `#Preview` seam, and it matters most here: a canvas that dialled
    /// would start a real agent in a real pane on the dev Mac.
    @Test("a parked model starts nothing")
    func parkedStartsNothing() async {
        let model = NewAgentModel(previewing: "reviewer", pane: "w2:p1", available: freePanes())
        #expect(await model.start(on: .preview) == .failed)
        #expect(model.failure == nil, "a parked start reported a failure, so it tried")
        #expect(model.warning == nil)
        #expect(!model.isStarting)
    }

    @Test("a parked model loads no panes and does not complain")
    func parkedLoadsNothing() async {
        let model = NewAgentModel(previewing: "")
        await model.loadPanes(for: .preview)
        #expect(model.available.isEmpty)
        #expect(model.failure == nil)
    }
}
