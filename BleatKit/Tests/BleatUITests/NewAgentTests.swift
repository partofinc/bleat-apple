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

    // MARK: - Getting another pane

    /// **The dead end this screen had, and the fix for it.** A workspace made
    /// from the phone holds exactly one pane; one agent fills it; and then
    /// Start is correctly disabled with nothing on screen to do about it.
    /// Measured on the dev Mac: every workspace in the live `work` session has
    /// one pane and every one is occupied.
    @Test("with no free pane there is still a way to get one")
    func offersAWayOut() {
        let model = NewAgentModel(previewing: "reviewer", workspace: "w2")
        #expect(model.available.isEmpty)
        #expect(!model.canStart, "there is nothing to start in")
        #expect(model.canAddPane, "and no way to get somewhere to start in")
    }

    /// **Only inside a workspace.** A tab belongs to one, and the session-wide
    /// agents list is not in one — guessing which workspace should gain a pane
    /// would put one in somebody's project.
    @Test("the session-wide list cannot add a pane, because it has no workspace")
    func noWorkspaceNoPane() {
        #expect(!NewAgentModel(previewing: "reviewer").canAddPane)
    }

    /// One action at a time: a start in flight must not be joined by a tab
    /// appearing underneath the picker it is reading from.
    @Test("adding and starting do not overlap")
    func oneAtATime() {
        let adding = NewAgentModel(
            previewing: "reviewer", pane: "w2:p1", workspace: "w2",
            available: Pane.samples, isAddingPane: true
        )
        #expect(!adding.canStart)

        let starting = NewAgentModel(
            previewing: "reviewer", pane: "w2:p1", workspace: "w2",
            available: Pane.samples, isStarting: true
        )
        #expect(!starting.canAddPane)
    }

    /// **An empty pane list means two different things**, and only one of them
    /// is a statement about the host. Saying "every pane already has an agent"
    /// over the top of a connection failure is a confident claim about a
    /// machine that was never reached.
    @Test("a host that never answered is not a host with no free panes")
    func doesNotClaimWhatItDoesNotKnow() {
        let unasked = NewAgentModel(previewing: "reviewer", workspace: "w2", hasLoadedPanes: false)
        #expect(!unasked.hasLoadedPanes)

        let answered = NewAgentModel(previewing: "reviewer", workspace: "w2")
        #expect(answered.hasLoadedPanes, "the parked default is a host that answered")
    }

    /// A parked model must not create a tab either — that is a pane on the dev
    /// Mac, from a canvas.
    @Test("a parked model adds no pane")
    func parkedAddsNothing() async {
        let model = NewAgentModel(previewing: "reviewer", workspace: "w2")
        await model.addPane(for: .preview)
        #expect(model.pane == nil)
        #expect(model.available.isEmpty)
        #expect(model.failure == nil, "a parked add reported a failure, so it tried")
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

    /// **A blocked agent disarms Start and "Add a pane" both.** The agent exists
    /// and needs answering; a retry is `agent_name_taken` or `agent_pane_busy`,
    /// and adding a pane would leave a stray tab on the user's Mac and repoint
    /// the form at an empty pane over an agent that still needs an answer.
    @Test("an agent waiting at a dialog disarms both actions")
    func blockedDisarmsEverything() {
        let model = NewAgentModel(
            previewing: "reviewer", pane: "w2:p1", workspace: "w2",
            available: Pane.samples,
            blocked: .init(message: "agent reviewer is blocked during startup", pane: "w2:p1")
        )
        #expect(!model.canStart)
        #expect(!model.canAddPane)
    }

    /// **The pane travels with the message.** The picker stays interactive in
    /// this state, so anything reading the *current* selection at tap time sends
    /// the user to whichever row they last touched — an unrelated shell — while
    /// the note still says an agent is waiting. Pinned because the type is the
    /// only thing preventing it.
    @Test("the blocked pane is the one the agent came up in, not the selection")
    func blockedCarriesItsOwnPane() {
        let model = NewAgentModel(
            previewing: "reviewer", pane: "w2:p1", available: Pane.samples,
            blocked: .init(message: "blocked during startup", pane: "w2:p1")
        )
        // The user taps another row in the picker, which is still live.
        model.pane = "w4:p1"
        #expect(model.blocked?.pane == "w2:p1")
    }

    /// Reopening the sheet clears it, like every other settled outcome: the
    /// model is `@State` on the screen and outlives the sheet.
    @Test("reopening the sheet clears a blocked agent")
    func resetClearsBlocked() {
        let model = NewAgentModel(
            previewing: "reviewer", pane: "w2:p1",
            blocked: .init(message: "blocked during startup", pane: "w2:p1")
        )
        model.reset()
        #expect(model.blocked == nil)
        #expect(model.canAddPane == false || model.addTo != nil)
    }
}
