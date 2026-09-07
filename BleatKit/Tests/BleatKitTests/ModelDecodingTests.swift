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

    /// **Captured live, 7 Sept 2026**, in an isolated probe workspace: a
    /// `claude` started in a directory it had never seen stops at the
    /// trust-this-folder dialog, which is exactly what herdr means by
    /// `blocked` — "Herdr recognized an approval or question UI".
    ///
    /// Two fields appear here that no previous fixture had, and both are
    /// absences rather than additions: a blocked agent has **no
    /// `agent_session`** and **no `interactive_ready`**, because neither is
    /// known until it is past the dialog. It carries `launch_pending: true`
    /// instead, which the model does not read. A required `agentSession` would
    /// have thrown on precisely the row the app most needs to show.
    @Test("a blocked agent decodes without a session id and sorts first")
    func blockedAgent() async throws {
        let transport = FakeTransport(
            responses: ["agent list": try Fixture.data("agent-list-blocked.json")]
        )
        let list = try await HerdrClient(transport: transport).agents()

        let blocked = try #require(list.first { $0.agentStatus == .blocked })
        #expect(blocked.paneID == "w2:p1")
        #expect(blocked.agentSession == nil)
        #expect(blocked.cwd == "/private/tmp/bleat-probe")
        // Sorted by attention, so the blocked row leads whatever else is live.
        #expect(list.first?.agentStatus == .blocked)
    }

    /// **Captured live, 7 Sept 2026.** `done` is not a terminal state and not a
    /// synonym for finished: herdr defines it as "the same underlying idle
    /// state after unseen background work finishes". Verified both halves —
    /// prompting this agent from an unfocused tab settled it to `done`, and
    /// `agent focus` immediately collapsed it back to `idle`. A CLI read does
    /// not, which is why nothing in Bleat calls focus: doing so on the phone
    /// would silently clear the marker for whoever is at the Mac.
    ///
    /// That is also why `done` outranks `idle` in `attentionRank`. The two
    /// differ by exactly one thing — whether anybody has looked.
    @Test("a done agent decodes and outranks an idle one")
    func doneAgent() async throws {
        let transport = FakeTransport(
            responses: ["agent list": try Fixture.data("agent-list-done.json")]
        )
        let list = try await HerdrClient(transport: transport).agents()

        let done = try #require(list.first { $0.agentStatus == .done })
        #expect(done.paneID == "w2:p1")
        #expect(done.agentSession?.value != nil)
        #expect(list.contains { $0.agentStatus == .idle })
        #expect(list.first?.agentStatus == .done)
    }

    /// Every state herdr documents has now been seen on a real host, which is
    /// what CLAUDE.md's open question asked for. `unknown` came from a freshly
    /// created pane before an agent was started in it.
    @Test("all five documented states have a live capture behind them")
    func everyStateIsCovered() throws {
        #expect(AgentStatus.allCases.count == 5)
    }

    @Test("unknown agent states decode rather than throw")
    func unknownStatus() throws {
        let json = Data(#"{"agent_status":"teleporting"}"#.utf8)
        struct Row: Decodable { let agent_status: AgentStatus }
        #expect(try JSONDecoder().decode(Row.self, from: json).agent_status == .unknown)
    }

    @Test("agents sort by who is waiting on a person: blocked, done, working, idle, unknown")
    func attentionOrder() {
        let shuffled: [AgentStatus] = [.done, .unknown, .working, .blocked, .idle]
        #expect(shuffled.sorted() == [.blocked, .done, .working, .idle, .unknown])
    }
}
