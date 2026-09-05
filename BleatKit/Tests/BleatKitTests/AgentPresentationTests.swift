import Foundation
import Testing
@testable import BleatKit

@Suite("Naming and addressing an agent")
struct AgentPresentationTests {

    private func agent(
        title: String? = nil,
        raw: String? = nil,
        kind: String? = nil,
        pane: String = "p1",
        workspace: String = "w2"
    ) -> Agent {
        Agent(
            paneID: pane, workspaceID: workspace, tabID: "t1", agentStatus: .idle,
            agent: kind, terminalTitle: raw, terminalTitleStripped: title
        )
    }

    /// The stripped title first: it is the raw one with escape sequences
    /// already removed, and a title carrying `ESC[...m` would render as
    /// gibberish in a list row.
    @Test("the stripped title wins when there is one")
    func prefersStripped() {
        #expect(agent(title: "Waiting for approval", raw: "\u{1B}[1mWaiting", kind: "claude")
            .displayTitle == "Waiting for approval")
    }

    @Test("then the raw title, then the agent's kind")
    func fallsBackInOrder() {
        #expect(agent(raw: "npm test", kind: "claude").displayTitle == "npm test")
        #expect(agent(kind: "claude").displayTitle == "claude")
    }

    /// Herdr sends empty strings as well as nulls, and an empty title is not a
    /// title. Without this every untitled pane renders as a blank row,
    /// indistinguishable from every other untitled pane.
    @Test("an empty or blank name is not a name")
    func rejectsBlankNames() {
        #expect(agent(title: "", raw: "   ", kind: "").displayTitle == "p1")
        #expect(agent(title: "  ").displayTitle == "p1")
    }

    /// The pane id is the last resort because it is at least unique.
    @Test("a nameless agent falls back to something that identifies it")
    func fallsBackToPaneID() {
        #expect(agent(pane: "p7").displayTitle == "p7")
    }

    /// Workspace ids are opaque and both short and long forms occur, so the
    /// target is built rather than assumed to follow a numbering.
    @Test("the pane target is workspace:pane")
    func target() {
        #expect(agent(pane: "p1", workspace: "w2").target == "w2:p1")
        #expect(agent(pane: "p3", workspace: "w653998617a6031").target == "w653998617a6031:p3")
    }
}
