import Foundation
import Testing
@testable import BleatKit

/// Which panes are plain shells, read off the host's own two lists.
///
/// Both fixtures were captured from the same running server, which is what
/// makes this worth asserting exactly: `pane list` carries ten panes and
/// `agent list` seven, so three of them are shells nothing else in the app
/// could see before.
@Suite("Terminal panes")
struct TerminalPanesTests {

    /// Read through the client, as the app reads them: the two lists are what
    /// one screen now asks for, and a hand-built model can be wrong in the same
    /// way the code is.
    private func host() throws -> HerdrClient {
        HerdrClient(transport: FakeTransport(responses: [
            "pane list": try Fixture.data("pane-list.json"),
            "agent list": try Fixture.data("agent-list.json"),
        ]))
    }

    private func panes() async throws -> [Pane] { try await host().panes() }
    private func agents() async throws -> [Agent] { try await host().agents() }

    @Test("the panes with no agent are what is left of pane list")
    func leftOver() async throws {
        let terminals = try await panes().withoutAgents(in: try await agents())
        #expect(terminals.map(\.paneID) == ["w3:p1", "w653ba939690ed1:p1", "w6537a1a27a64d2:p1"])
    }

    /// The rule that decides, stated on its own: a pane an agent occupies is
    /// not a free terminal, however the pane's own fields read.
    @Test("a pane an agent occupies is never offered")
    func occupiedIsExcluded() async throws {
        let all = try await panes()
        let agent = try #require(try await agents().first)
        #expect(all.contains { $0.paneID == agent.paneID })
        #expect(!all.withoutAgents(in: [agent]).contains { $0.paneID == agent.paneID })
    }

    /// The case `agent list` exists to cover and a pane's own fields do not: a
    /// start that timed out leaves herdr holding a detected agent it never got
    /// to name. That pane belongs to somebody.
    @Test("a nameless agent still occupies its pane")
    func namelessAgentOccupies() async throws {
        let json = """
        {"pane_id":"w3:p1","workspace_id":"w3","tab_id":"w3:t1",
         "agent_status":"working","focused":false}
        """
        let nameless = try JSONDecoder().decode(Agent.self, from: Data(json.utf8))
        #expect(nameless.name == nil)
        let terminals = try await panes().withoutAgents(in: [nameless])
        #expect(!terminals.contains { $0.paneID == "w3:p1" })
    }

    /// Ordered the way the agents above them are, or a workspace that reaches
    /// ten panes lists them wrong.
    @Test("panes are ordered naturally")
    func naturalOrder() throws {
        let body = """
        [{"pane_id":"w1:p10","workspace_id":"w1","tab_id":"w1:t1","agent_status":"unknown","focused":false},
         {"pane_id":"w1:p2","workspace_id":"w1","tab_id":"w1:t1","agent_status":"unknown","focused":false}]
        """
        let panes = try JSONDecoder().decode([Pane].self, from: Data(body.utf8))
        #expect(panes.withoutAgents(in: []).map(\.paneID) == ["w1:p2", "w1:p10"])
    }

    /// A shell titles itself with where it is; a pane that says nothing falls
    /// back to its id, which is at least unique. Never blank — an untitled row
    /// is otherwise indistinguishable from every other untitled row.
    @Test("a pane names itself, and never with an empty string")
    func naming() async throws {
        let terminals = try await panes().withoutAgents(in: try await agents())
        #expect(terminals.first?.displayTitle == "robin@studio-mac:~/Developer/zenith/link-apple")
        #expect(terminals.allSatisfy { !$0.displayTitle.isEmpty })

        let body = """
        {"pane_id":"w9:p1","workspace_id":"w9","tab_id":"w9:t1","agent_status":"unknown",
         "focused":false,"terminal_title":"   "}
        """
        let untitled = try JSONDecoder().decode(Pane.self, from: Data(body.utf8))
        #expect(untitled.displayTitle == "w9:p1")
        #expect(untitled.target == "w9:p1")
    }
}
