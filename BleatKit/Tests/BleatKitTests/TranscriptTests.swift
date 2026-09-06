import Foundation
import Testing
@testable import BleatKit

@Suite("Reading an agent's own transcript")
struct TranscriptTests {

    /// The fixture is **synthetic**, and deliberately so: the schema was
    /// verified against a real 183MB Claude Code transcript on 6 Sept 2026 —
    /// record types, block types, the two `content` shapes, `isMeta`,
    /// `isSidechain` — but the real file is a private conversation and does not
    /// belong in a repository. Every shape asserted here was seen in that file.
    @Test("prose turns are kept, in order")
    func keepsProse() throws {
        let entries = Transcript.entries(from: try Fixture.data("transcript.jsonl"))
        let main = entries.filter { !$0.isSidechain }
        #expect(main.map(\.id) == ["u1", "a1", "u4", "a4"])
        #expect(main.map(\.role) == [.user, .assistant, .user, .assistant])
        #expect(main[0].text == "Add a --json flag to the export command.")
    }

    /// The second-largest block kind in the real file. It is the agent talking
    /// to itself, and putting it in a reader buries the answer under the
    /// working out.
    @Test("thinking is not shown")
    func dropsThinking() throws {
        let entries = Transcript.entries(from: try Fixture.data("transcript.jsonl"))
        #expect(!entries.contains { $0.text.contains("Check the CLI first") })
        // …but the text block beside it in the same record survives.
        #expect(entries.contains { $0.id == "a1" && $0.text.hasPrefix("I'll add it") })
    }

    /// `tool_use` and `tool_result` were 6,062 of 22,064 records. A turn that
    /// was only a tool call has no prose, and rendering it would space the
    /// conversation out with nothing in the gaps.
    @Test("tool traffic does not become blank rows")
    func dropsToolTraffic() throws {
        let entries = Transcript.entries(from: try Fixture.data("transcript.jsonl"))
        #expect(!entries.contains { $0.id == "a2" || $0.id == "u2" })
        #expect(!entries.contains { $0.text.isEmpty })
    }

    /// Injected by the harness rather than typed. Addressed to the agent, not
    /// to the person reading over its shoulder.
    @Test("meta messages are not shown")
    func dropsMeta() throws {
        let entries = Transcript.entries(from: try Fixture.data("transcript.jsonl"))
        #expect(!entries.contains { $0.id == "u3" })
    }

    /// Kept and flagged rather than dropped in the parser: whether this was the
    /// agent or something it spawned is the reader's question to answer.
    @Test("a subagent's turn is kept but marked")
    func flagsSidechain() throws {
        let entries = Transcript.entries(from: try Fixture.data("transcript.jsonl"))
        let side = try #require(entries.first { $0.id == "a3" })
        #expect(side.isSidechain)
    }

    /// Both forms occur in one real file.
    @Test("content as a bare string is read as well as as blocks")
    func readsBareStringContent() throws {
        let entries = Transcript.entries(from: try Fixture.data("transcript.jsonl"))
        #expect(entries.first { $0.id == "u4" }?.text == "and update the tests")
    }

    @Test("timestamps with fractional seconds parse")
    func parsesTimestamps() throws {
        let entries = Transcript.entries(from: try Fixture.data("transcript.jsonl"))
        #expect(entries.first { $0.id == "u1" }?.timestamp != nil)
    }

    /// The input is the tail of a file a live process is appending to, fetched
    /// through a filter. A truncated line, a record whose shape has moved and a
    /// type this build never heard of are all expected — and a reader that
    /// failed closed would go blank exactly when the agent was busiest.
    @Test("damage is skipped, not thrown")
    func survivesDamage() {
        let data = Data("""
            {"type":"assistant","uuid":"a1","message":{"content":[{"type":"text","tex
            not json at all
            {"type":"assistant","uuid":"ok","message":{"role":"a","content":[{"type":"text","text":"survived"}]}}
            {"type":"unheard_of","uuid":"x"}
            """.utf8)
        let entries = Transcript.entries(from: data)
        #expect(entries.map(\.id) == ["ok"])
    }
}

@Suite("Locating a transcript on the host")
struct TranscriptCommandTests {

    /// The id arrives as JSON *from the host* and is then spliced into a command
    /// that host will run. Validated rather than escaped, for the reason
    /// `AuthorizedKeys.Marker` is.
    @Test("a real session id is accepted")
    func acceptsAUUID() {
        #expect(TranscriptCommand.isSafe("0f7a74a0-560a-490e-8b83-b70930263a4a"))
    }

    @Test(
        "anything that is not an identifier is refused",
        arguments: [
            "a b", "a;rm -rf /", "a$(id)", "a`id`", "a|b", "a&b", "a>b", "a'b", "a\"b",
            "../../../etc/passwd", "a/b", "-rf", ".hidden", "", "a\nb", "a*b",
        ]
    )
    func refusesEverythingElse(id: String) {
        #expect(!TranscriptCommand.isSafe(id))
        #expect(TranscriptCommand.read(sessionID: id) == nil)
    }

    /// Every character is allowed on its own; a `..` component inside the glob
    /// is how a lookup climbs out of `~/.claude/projects`.
    @Test("a dot-dot component is refused even though its characters are legal")
    func refusesTraversal() {
        #expect(TranscriptCommand.isSafe("a.b"))
        #expect(!TranscriptCommand.isSafe("a..b"))
    }

    /// The filtering has to happen on the host. One real transcript was 183MB
    /// with single records up to 1.3MB; nothing may read the file whole.
    @Test("the command bounds the read on the host, before anything is sent")
    func filtersOnTheHost() throws {
        let command = try #require(TranscriptCommand.read(sessionID: "abc", turns: 40, scanning: 900))
        #expect(command.contains("tail -n 900"))
        #expect(command.contains("tail -n 40"))
        #expect(command.contains("length($0) < 131072"))
        #expect(!command.contains("cat "))
    }

    /// sshd runs this through the login shell, and zsh sources `.zshenv` even
    /// non-interactively — so a user's `alias ls=eza` is in scope. eza's `-t`
    /// takes a field argument, swallows the path and returns nothing, making
    /// the transcript silently "not found". This repository's own dev Mac has
    /// that alias and reproduced it.
    @Test("the lookup cannot be hijacked by a shell alias")
    func bypassesAliases() throws {
        let command = try #require(TranscriptCommand.read(sessionID: "abc"))
        #expect(command.contains("command ls -t"))
    }

    /// **The fixture has to be in the form the host-side filter matches.** The
    /// pre-filter greps for the compact `"type":"user"`, and a fixture written
    /// with spaces after the colons would be discarded by the real pipeline
    /// while still passing every parser test — so the only in-repo sample of
    /// the format would be one that could never arrive. Verified against a real
    /// transcript: 635 matches for the compact form, none for the spaced one.
    @Test("the fixture is in the form the host-side filter matches")
    func fixtureMatchesTheFilter() throws {
        let raw = String(decoding: try Fixture.data("transcript.jsonl"), as: UTF8.self)
        #expect(raw.contains("\"type\":\"user\""))
        #expect(raw.contains("\"type\":\"assistant\""))
        #expect(!raw.contains("\"type\": \""))
    }

    /// The size bound must not exclude ordinary prose. Measured on a live
    /// transcript, seven of 635 conversational records exceeded 16KB and every
    /// one was a long prompt or a long answer.
    @Test("the size bound leaves room for a long turn")
    func boundLeavesRoomForProse() throws {
        let command = try #require(TranscriptCommand.read(sessionID: "abc"))
        let digits = command
            .components(separatedBy: "length($0) < ").last?
            .prefix { $0.isNumber } ?? ""
        let bound = Int(digits) ?? 0
        #expect(bound >= 65536, "a 64KB turn is ordinary prose, not an attachment")
    }

    /// An agent with no transcript is a normal answer, not a failed command —
    /// every stage of the pipeline exits non-zero on "nothing matched".
    @Test("a missing transcript is not an error")
    func missingIsNotAnError() throws {
        let command = try #require(TranscriptCommand.read(sessionID: "abc"))
        #expect(command.hasSuffix("|| true"))
    }
}

@Suite("Following an agent while the chat is open")
struct AgentWaitTests {

    /// The exact argv, because none of it is checked at compile time and every
    /// part is load-bearing. `--timeout` especially: without it the wait is
    /// indefinite, which pins an exec channel open on the host forever when a
    /// phone sleeps mid-wait.
    @Test("it long-polls for the settled states, with a bounded timeout")
    func buildsTheWait() async throws {
        let command = "agent wait w5:p1 --timeout 25000 --until idle --until blocked --until done"
        let client = HerdrClient(transport: FakeTransport(
            responses: [command: try Fixture.data("agent-get.json")]
        ))
        // FakeTransport throws on any command it was not given, so returning
        // at all is the assertion on the argv.
        let agent = try await client.waitForAgent(
            target: "w5:p1", until: [.idle, .blocked, .done], timeoutMs: 25_000
        )
        #expect(agent.paneID == "w5:p1")
        #expect(agent.agentSession?.value == "0f7a74a0-560a-490e-8b83-b70930263a4a")
    }

    /// `agent get` and `agent wait` return the same `agent_info` shape — which
    /// is what lets the chat learn the agent's state from the call it already
    /// had to make to find the transcript.
    @Test("agent get decodes the session pointer the chat needs")
    func decodesAgentGet() async throws {
        let client = HerdrClient(transport: FakeTransport(
            responses: ["agent get w5:p1": try Fixture.data("agent-get.json")]
        ))
        let agent = try await client.agent(target: "w5:p1")
        #expect(agent.agentStatus == .idle)
        #expect(agent.agentSession?.kind == "id")
        // The pane id is already the full target; joining the workspace on
        // again gives `w5:w5:p1` and the host answers `pane_not_found`.
        #expect(agent.target == "w5:p1")
    }
}
