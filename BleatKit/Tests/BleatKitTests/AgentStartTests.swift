import Foundation
import Testing
@testable import BleatKit

/// Starting an agent in a pane.
///
/// Read off herdr 0.9.0 on the dev Mac (9 Sept 2026) in a disposable session,
/// including a real `claude` started, a real one started by hand, and a real
/// timeout. The shape of this feature is decided by two of those measurements:
/// every refusal is instant, and a timeout is not a refusal.
@Suite("Starting an agent")
struct AgentStartTests {

    // MARK: - The name

    /// herdr states the rule itself, so this is its wording rather than a
    /// guess: "agent name must start with a lowercase letter and contain only
    /// lowercase letters, digits, '-' or '_' (1-32 characters)".
    @Test("herdr's own character set is what is allowed", arguments: [
        "reviewer", "probe-a", "a", "claude_2", "x1", "a-b_c9",
    ])
    func acceptsWhatHerdrAccepts(_ name: String) {
        #expect(AgentName(name) != nil, "\(name) should be a usable agent name")
    }

    /// The capital is the one most likely to surprise, and it is reported as a
    /// character problem rather than a first-character one: the user can see
    /// that `Reviewer` starts with a letter, so "start with a lowercase letter"
    /// alone would read as a contradiction.
    @Test("anything herdr would refuse is refused here", arguments: [
        "my agent", "Reviewer", "agent.1", "a/b", "wörk", "a!b",
    ])
    func refusesWhatHerdrRefuses(_ name: String) {
        #expect(AgentName.problem(with: name) == .illegalCharacters)
    }

    @Test("a name must start with a lowercase letter", arguments: ["1st", "-a", "_a"])
    func mustStartWithALetter(_ name: String) {
        #expect(AgentName.problem(with: name) == .badFirstCharacter)
    }

    @Test("an empty name is its own answer, not an illegal character")
    func emptyIsItsOwnProblem() {
        // The field's resting state, reported separately so a blank field is
        // not shouted at as though the user had typed something wrong.
        #expect(AgentName.problem(with: "") == .empty)
    }

    @Test("herdr's 32-character limit is enforced here")
    func lengthLimit() {
        #expect(AgentName(String(repeating: "a", count: 32)) != nil)
        #expect(AgentName.problem(with: String(repeating: "a", count: 33)) == .tooLong)
    }

    // MARK: - The kind

    /// herdr 0.9.3 offers twenty-four, and this is its own order.
    ///
    /// **It was twenty-three, and the twenty-fourth is `letta`** — read off
    /// `agent start --help` on a live host, 30 Sept 2026. The count is asserted
    /// so that falling behind is something a test says rather than something a
    /// user finds missing from the picker.
    @Test("the kinds are herdr's, in herdr's order")
    func knownKinds() {
        #expect(AgentKind.known.count == 24)
        #expect(AgentKind.known.first == AgentKind("pi"))
        #expect(AgentKind.known.contains(.claude))
        #expect(AgentKind.known.contains(AgentKind("letta")), "0.9.3 added this one")
        // herdr's order, not alphabetical: `letta` sits between `qwen` and
        // `maki` exactly where herdr lists it.
        #expect(AgentKind.known.map(\.rawValue).suffix(3) == ["letta", "maki", "muse"])
    }

    /// **Not a closed enum**, so a herdr that grows a twenty-fourth kind stays
    /// usable rather than making its own reply undecodable — the "unknown
    /// values must decode, never throw" rule applied to a value.
    ///
    /// **This is no longer hypothetical.** 0.9.3 did grow one, and the only
    /// cost of the app not knowing about it was a picker that did not offer it:
    /// nothing failed to decode, and no agent row broke.
    @Test("a kind this build has not heard of is still a kind")
    func toleratesAnUnknownKind() throws {
        let body = Data(#""somethingnew""#.utf8)
        let kind = try JSONDecoder().decode(AgentKind.self, from: body)
        #expect(kind.rawValue == "somethingnew")
        // And it falls back to herdr's own spelling rather than blanking.
        #expect(kind.label == "somethingnew")
    }

    // MARK: - The command

    @Test("the name, kind, pane and timeout are sent as herdr's own flags")
    func buildsTheCommand() async throws {
        let transport = RecordingTransport(reply: try Fixture.data("agent-start.json"))
        _ = try await HerdrClient(transport: transport).startAgent(
            named: AgentName("reviewer")!, kind: .claude, pane: "w1:p1"
        )

        let args = try #require(transport.commands.first)
        #expect(args.prefix(3) == ["agent", "start", "reviewer"])
        #expect(args.contains("--kind"))
        #expect(args.contains("claude"))
        #expect(args.contains("--pane"))
        #expect(args.contains("w1:p1"))
        #expect(args.contains("--timeout"))
        #expect(args.contains(String(AgentStart.defaultTimeoutMs)))
    }

    /// herdr's bound, which its `--help` does not print: below it the command
    /// answers `invalid_agent_timeout` and nothing is started.
    @Test("the default budget is inside herdr's bounds")
    func timeoutIsLegal() {
        #expect(AgentStart.defaultTimeoutMs > 3_000)
        #expect(AgentStart.defaultTimeoutMs <= AgentStart.maximumTimeoutMs)
        #expect(AgentStart.minimumTimeoutMs > 3_000)
    }

    @Test("the reply is the agent that started")
    func decodesTheReply() throws {
        let agent = try JSONDecoder()
            .decode(HerdrEnvelope<AgentInfoResult>.self, from: Fixture.data("agent-start.json"))
            .result.agent
        #expect(agent.name == "reviewer")
        #expect(agent.agent == "claude")
        #expect(agent.paneID == "w1:p1")
    }

    // MARK: - What a failure means

    /// **A timeout is not a refusal, and this is the measurement that decides
    /// the whole screen.** A `claude` given a 3.5s budget against a 4.9s cold
    /// start answered `timed out waiting for agent startup` — and the pane then
    /// held a running, detected claude with `name: null`. Reporting that as a
    /// plain failure invites a retry, which lands on `agent_pane_busy` because
    /// the pane now holds the agent the user was told had not started.
    @Test("a timeout is not a refusal")
    func aTimeoutIsNotARefusal() {
        #expect(!AgentStart.isRefusalBeforeTyping(
            herdr("timeout", "timed out waiting for agent startup")
        ))
    }

    /// **`agent_not_ready` is not a refusal either, and this one reached a
    /// device.** It is what herdr answers when the agent came up and stopped at
    /// a dialog — the Claude Code workspace-trust prompt, which a directory it
    /// has never seen always produces, so it is the *common* case for an agent
    /// started in a workspace the phone just made.
    ///
    /// Measured 12 Sept 2026 in an isolated session against a fresh directory:
    /// exit 1 in **3.9s** with
    /// `{"code":"agent_not_ready","message":"agent probe is blocked during
    /// startup and is not ready for prompts"}` — and `agent list` then held
    /// `name: "probe"`, `launch_pending: true`. The agent exists *and is named*.
    ///
    /// Because the code is not `timeout`, the old rule called it a refusal and
    /// the phone reported "nothing happened" with the button still armed, over
    /// an agent sitting in that pane. Both retries are dead ends, also measured:
    /// the same name answers `agent_name_taken`, any other name answers
    /// `agent_pane_busy`.
    @Test("an agent blocked at a dialog is not a refusal")
    func blockedDuringStartupIsNotARefusal() {
        let error = herdr(
            "agent_not_ready",
            "agent probe is blocked during startup and is not ready for prompts"
        )
        #expect(!AgentStart.isRefusalBeforeTyping(error))
        #expect(AgentStart.isBlockedDuringStartup(error))
    }

    /// Told apart from a timeout on purpose: a timeout is ambiguous and gets
    /// read back, while this is herdr positively saying the agent is there. The
    /// remedy differs, so the classification has to.
    @Test("only agent_not_ready is the blocked outcome", arguments: [
        "timeout", "agent_pane_busy", "agent_name_taken", "invalid_agent_name",
        "agent_pane_not_found", "invalid_agent_timeout",
    ])
    func nothingElseIsBlocked(_ code: String) {
        #expect(!AgentStart.isBlockedDuringStartup(herdr(code, "something")))
    }

    /// Not a `HerdrError` at all, so not a positive statement about anything.
    @Test("a transport failure is not the blocked outcome")
    func transportIsNotBlocked() {
        #expect(!AgentStart.isBlockedDuringStartup(TransportError.connectionFailed("closed")))
    }

    /// Everything else herdr says, it says **before typing anything** — each
    /// measured under 30ms — so the pane is untouched and a retry is safe.
    @Test("every other refusal happened before anything was typed", arguments: [
        "agent_pane_not_found", "agent_pane_busy", "invalid_agent_name",
        "agent_name_taken", "invalid_agent_timeout",
    ])
    func everythingElseIsARefusal(_ code: String) {
        #expect(AgentStart.isRefusalBeforeTyping(herdr(code, "refused")))
    }

    /// **The question is "did herdr answer", not "was it a timeout", and an
    /// earlier version asked the wrong one.** `agent start` blocks on the host
    /// for up to thirty seconds while herdr types the executable in, so a
    /// dropped connection says nothing about whether the command ran — and a
    /// reply this build could not read means it certainly did. Both were being
    /// reported as "nothing happened, try again", and the retry lands on
    /// `agent_pane_busy` over an agent nobody named.
    @Test("anything that is not herdr answering has to be checked")
    func onlyHerdrCanSettleIt() {
        #expect(!AgentStart.isRefusalBeforeTyping(TransportError.connectionFailed("closed")))
        #expect(!AgentStart.isRefusalBeforeTyping(
            DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "not json"))
        ))
        #expect(!AgentStart.isRefusalBeforeTyping(CancellationError()))
    }

    // MARK: - Reading the cause out of the pane

    /// **The pane is the only place the cause is written.** herdr's own answer
    /// names nothing; the pane holds the shell's complaint. Captured verbatim
    /// from a start with a kind whose binary is not installed.
    @Test("a missing binary is explained by the pane, not by herdr")
    func findsTheShellComplaint() {
        let pane = [
            "devin",
            "➜  bleat-apple devin",
            "zsh: command not found: devin",
            "➜  bleat-apple git:(main)",
        ]
        #expect(AgentStart.diagnosis(inPane: pane, kind: AgentKind("devin"))
            == "zsh: command not found: devin")
    }

    @Test("other shells' wording is read too", arguments: [
        "sh: 1: devin: not found",
        "bash: devin: command not found",
        "env: devin: No such file or directory",
    ])
    func readsOtherShells(_ line: String) {
        #expect(AgentStart.diagnosis(inPane: [line], kind: AgentKind("devin")) == line)
    }

    /// **A substring is not a mention, and the short kinds are why.** herdr
    /// offers `pi`, `amp`, `agy`, `omp` and `kimi`, and one of the complaints
    /// matched is the very generic "No such file or directory" — so a line left
    /// on screen by something the user did earlier would be quoted back as the
    /// reason `pi` failed to start.
    @Test("a line that merely contains the kind's letters is not a cause")
    func doesNotMatchOnASubstring() {
        let pane = ["cat: /Users/ravil/api/keys: No such file or directory"]
        #expect(AgentStart.diagnosis(inPane: pane, kind: AgentKind("pi")) == nil)
        // And the same complaint that really is about `pi` still reads.
        #expect(AgentStart.diagnosis(
            inPane: ["env: pi: No such file or directory"], kind: AgentKind("pi")
        ) != nil)
    }

    /// **Never a guess.** A pane that says nothing about the agent we asked for
    /// gets no diagnosis, and the caller says the honest "it did not come up in
    /// time" — the mistake `SessionStarter` made once was offering herdr's own
    /// startup banner as the reason it had not started.
    @Test("an unrelated pane explains nothing")
    func doesNotInventACause() {
        let pane = ["➜  bleat-apple git:(main)", "some output from something else"]
        #expect(AgentStart.diagnosis(inPane: pane, kind: .claude) == nil)
        #expect(AgentStart.diagnosis(inPane: [], kind: .claude) == nil)
    }

    /// A pane where the agent is plainly coming up is not a failure to explain.
    @Test("a working start is not read as a complaint")
    func doesNotMisreadSuccess() {
        #expect(AgentStart.diagnosis(inPane: ["✳ Claude Code", "claude"], kind: .claude) == nil)
    }

    // MARK: - Named and nameless agents

    /// **An agent started by hand at the Mac has no name**, and that is
    /// ordinary rather than exotic: herdr only knows a name if it gave one out.
    /// Captured live — two agents started through `agent start` beside one
    /// started by typing `claude` in a pane.
    @Test("the list carries names, and tolerates their absence")
    func decodesNamedAndNameless() throws {
        let agents = try JSONDecoder()
            .decode(HerdrEnvelope<AgentList>.self, from: Fixture.data("agent-list-named.json"))
            .result.agents

        #expect(agents.count == 3)
        #expect(agents.compactMap(\.name).sorted() == ["latecomer", "reviewer"])
        let byHand = try #require(agents.first { $0.name == nil })
        // Detected and listed all the same: it is a real agent, just not one
        // herdr was asked to start.
        #expect(byHand.agent == "claude")
    }

    // MARK: - Getting another pane

    /// **A tab, not a `pane split`, and the geometry is the whole argument.**
    /// Both give a pane an agent can start in immediately — measured, 3.9s and
    /// 4.4s. What differs is what they cost whoever is at the Mac, in a
    /// 120-column session:
    ///
    /// | | pane rect |
    /// |---|---|
    /// | `pane split --direction right` | 60 × 40 |
    /// | `tab create` | 120 × 40 |
    ///
    /// A split halves the pane it came from as well as the new one, and this
    /// codebase spends pages on what a narrow grid does to an agent's output.
    @Test("another pane is asked for as a tab")
    func addsATab() async throws {
        let transport = RecordingTransport(reply: try Fixture.data("tab-create.json"))
        _ = try await HerdrClient(transport: transport).createTab(inWorkspace: "w1")

        let args = try #require(transport.commands.first)
        #expect(args.prefix(2) == ["tab", "create"])
        #expect(args.contains("--workspace"))
        #expect(args.contains("w1"))
        #expect(args.contains("split") == false)
    }

    /// **No `--cwd`, and that is measured rather than lazy.** A new tab's pane
    /// inherits the *workspace's* directory, not the server's — verified
    /// against a workspace in `/Users/ravil/Developer` while the server had
    /// been started in the repo root. `workspace create` is the opposite, which
    /// is why that one must always be told. So adding a pane needs no path
    /// typed on a phone.
    @Test("a tab inherits the workspace's directory, so none is sent")
    func sendsNoDirectory() async throws {
        let transport = RecordingTransport(reply: try Fixture.data("tab-create.json"))
        _ = try await HerdrClient(transport: transport).createTab(inWorkspace: "w1")
        #expect(try #require(transport.commands.first).contains("--cwd") == false)
    }

    /// The same rule as everywhere else: focusing moves the view of whoever is
    /// at the Mac.
    @Test("adding a tab does not take focus")
    func doesNotFocus() async throws {
        let transport = RecordingTransport(reply: try Fixture.data("tab-create.json"))
        _ = try await HerdrClient(transport: transport).createTab(inWorkspace: "w1")
        let args = try #require(transport.commands.first)
        #expect(args.contains("--no-focus"))
        #expect(args.contains("--focus") == false)
    }

    /// A tab is never empty either — it arrives holding one pane running a
    /// shell. The fixture's pane id is `w1:pA`, a reminder that these are
    /// opaque: both `p2` and `pA` forms occur.
    @Test("the reply carries the tab and the pane it brought")
    func decodesTheTabReply() throws {
        let created = try JSONDecoder()
            .decode(HerdrEnvelope<TabCreated>.self, from: Fixture.data("tab-create.json"))
            .result
        #expect(created.tab.tabID == "w1:t2")
        #expect(created.rootPane?.paneID == "w1:pA")
        #expect(created.rootPane?.tabID == "w1:t2")
    }

    /// The same `try?`-per-sibling tolerance `WorkspaceCreated` has, for the
    /// same measured reason: a plain optional throws on a malformed key, and
    /// that would report a failure over a tab that exists on someone's Mac.
    @Test("a pane this build cannot read does not cost the tab")
    func toleratesAMalformedPane() throws {
        let body = Data(#"""
        {"tab":{"tab_id":"w1:t2","workspace_id":"w1"},
         "root_pane":{"pane_id":"w1:pA","workspace_id":"w1","tab_id":"w1:t2",
                      "agent_status":"unknown","focused":"yes"}}
        """#.utf8)
        let created = try JSONDecoder().decode(TabCreated.self, from: body)
        #expect(created.tab.tabID == "w1:t2")
        #expect(created.rootPane == nil, "a malformed pane should be dropped, not thrown")
    }

    private func herdr(_ code: String, _ message: String) -> HerdrError {
        HerdrError(
            command: ["agent", "start"], exitCode: 1, stderr: "", code: code, message: message
        )
    }
}
