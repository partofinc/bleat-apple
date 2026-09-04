import Foundation
import Testing
@testable import BleatKit

@Suite("Decoding captured herdr output")
struct ModelDecodingTests {

    @Test("workspace list decodes every row")
    func workspaces() async throws {
        let transport = FakeTransport(
            responses: ["workspace list": try Fixture.data("workspace-list.json")]
        )
        let list = try await HerdrClient(transport: transport).workspaces()

        #expect(list.count == 10)
        let bleat = try #require(list.first { $0.label == "bleat-apple" })
        #expect(bleat.workspaceID == "wA")
        #expect(bleat.agentStatus == .working)
        #expect(bleat.focused)
        #expect(bleat.activeTabID == "wA:t1")
    }

    @Test("agent list carries cwd and pane target, so no join is needed")
    func agents() async throws {
        let transport = FakeTransport(
            responses: ["agent list": try Fixture.data("agent-list.json")]
        )
        let list = try await HerdrClient(transport: transport).agents()

        #expect(!list.isEmpty)
        let first = try #require(list.first)
        #expect(first.cwd != nil)
        #expect(first.paneID.contains(":"))
        // The Claude session id is what will let Bleat badge two accounts apart.
        #expect(list.contains { $0.agentSession?.value != nil })
    }

    @Test("pane list decodes scroll position")
    func panes() async throws {
        let transport = FakeTransport(
            responses: ["pane list": try Fixture.data("pane-list.json")]
        )
        let list = try await HerdrClient(transport: transport).panes()
        let scrolled = try #require(list.first { $0.scroll != nil })
        #expect(scrolled.scroll?.viewportRows != nil)
    }

    @Test("session list is unenveloped and needs --json")
    func sessions() async throws {
        let transport = FakeTransport(
            responses: ["session list --json": try Fixture.data("session-list.json")]
        )
        let list = try await HerdrClient(transport: transport).sessions()
        #expect(list.count == 2)
        let work = try #require(list.first { $0.name == "work" })
        #expect(work.running)
        #expect(work.isDefault == false)
        #expect(work.socketPath?.hasSuffix("herdr.sock") == true)
    }

    @Test("unknown agent states decode rather than throw")
    func unknownStatus() throws {
        let json = Data(#"{"agent_status":"teleporting"}"#.utf8)
        struct Row: Decodable { let agent_status: AgentStatus }
        #expect(try JSONDecoder().decode(Row.self, from: json).agent_status == .unknown)
    }

    @Test("agents sort blocked first, then working, idle, done, unknown")
    func attentionOrder() {
        let shuffled: [AgentStatus] = [.done, .unknown, .working, .blocked, .idle]
        #expect(shuffled.sorted() == [.blocked, .working, .idle, .done, .unknown])
    }
}
