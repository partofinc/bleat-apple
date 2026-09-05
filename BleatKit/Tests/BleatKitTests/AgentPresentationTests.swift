import Foundation
import Testing
@testable import BleatKit

@Suite("Naming and addressing an agent")
struct AgentPresentationTests {

    private func agent(
        title: String? = nil,
        raw: String? = nil,
        kind: String? = nil,
        pane: String = "w2:p1",
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
        #expect(agent(title: "", raw: "   ", kind: "").displayTitle == "w2:p1")
        #expect(agent(title: "  ").displayTitle == "w2:p1")
    }

    /// The pane id is the last resort because it is at least unique — and it
    /// is a full target, `w2:p7`, which is what the host sends.
    @Test("a nameless agent falls back to something that identifies it")
    func fallsBackToPaneID() {
        #expect(agent(pane: "w2:p7").displayTitle == "w2:p7")
    }

    /// Read from the captured host output rather than from a hand-built
    /// `Agent`, because the shape is the whole point: `pane_id` arrives as
    /// `"w2:p1"` — already the full target — alongside `"workspace_id":"w2"`.
    /// A test that invented a bare `"p1"` passed happily while `target`
    /// returned `w2:w2:p1`, which would have failed every attach in Phase 3.
    @Test("the pane target is what the host already sent, not a rebuilt one")
    func targetComesFromTheHost() throws {
        let data = try Fixture.data("agent-list.json")
        let agents = try JSONDecoder().decode(HerdrEnvelope<AgentList>.self, from: data).result.agents
        #expect(!agents.isEmpty)
        for agent in agents {
            #expect(agent.target == agent.paneID)
            // One colon: `workspace:pane`. Two means it was joined twice.
            #expect(agent.target.filter { $0 == ":" }.count == 1)
            #expect(agent.target.hasPrefix("\(agent.workspaceID):"))
        }
    }
}
