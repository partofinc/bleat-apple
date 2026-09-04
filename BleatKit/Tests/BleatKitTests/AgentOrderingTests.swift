import Foundation
import Testing
@testable import BleatKit

@Suite("Agent ordering")
struct AgentOrderingTests {

    private func agent(_ paneID: String, _ status: AgentStatus) -> Agent {
        let json = """
        {"pane_id":"\(paneID)","workspace_id":"w1","tab_id":"w1:t1",
         "agent_status":"\(status.rawValue)","focused":false}
        """
        return try! JSONDecoder().decode(Agent.self, from: Data(json.utf8))
    }

    @Test("attention state comes before pane order")
    func statusFirst() {
        let sorted = [
            agent("w1:p1", .idle),
            agent("w1:p2", .blocked),
            agent("w1:p3", .working),
        ].sortedByAttention()
        #expect(sorted.map(\.agentStatus) == [.blocked, .working, .idle])
    }

    @Test("panes are ordered naturally, not lexicographically")
    func naturalPaneOrder() {
        // Plain string ordering puts p10 before p2, so any workspace that
        // reaches ten panes listed them wrong.
        let sorted = [
            agent("w1:p10", .idle),
            agent("w1:p2", .idle),
            agent("w1:p1", .idle),
        ].sortedByAttention()
        #expect(sorted.map(\.paneID) == ["w1:p1", "w1:p2", "w1:p10"])
    }

    @Test("workspace numbers order naturally too")
    func naturalWorkspaceOrder() {
        let sorted = [
            agent("w10:p1", .idle),
            agent("w2:p1", .idle),
        ].sortedByAttention()
        #expect(sorted.map(\.paneID) == ["w2:p1", "w10:p1"])
    }

    @Test("opaque workspace ids still sort deterministically")
    func opaqueIDs() {
        // Both short and long forms occur live: w2, wA, w653998617a6031.
        let ids = ["w653998617a6031:p1", "wA:p1", "w2:p1"]
        let sorted = ids.map { agent($0, .idle) }.sortedByAttention().map(\.paneID)
        #expect(sorted.count == 3)
        #expect(Set(sorted) == Set(ids))
        // Stable across runs: sorting the result again changes nothing.
        #expect(sorted.map { agent($0, .idle) }.sortedByAttention().map(\.paneID) == sorted)
    }

    @Test("the client returns agents already in this order")
    func clientMatches() async throws {
        let transport = FakeTransport(
            responses: ["agent list": try Fixture.data("agent-list.json")]
        )
        let fromClient = try await HerdrClient(transport: transport).agents()
        // The client must not have its own comparator to drift from.
        #expect(fromClient.map(\.paneID) == fromClient.sortedByAttention().map(\.paneID))
    }
}
