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

    /// herdr 0.9.0 offers twenty-three, and this is its own order.
    @Test("the kinds are herdr's, in herdr's order")
    func knownKinds() {
        #expect(AgentKind.known.count == 23)
        #expect(AgentKind.known.first == AgentKind("pi"))
        #expect(AgentKind.known.contains(.claude))
    }

    /// **Not a closed enum**, so a herdr that grows a twenty-fourth kind stays
    /// usable rather than making its own reply undecodable — the "unknown
    /// values must decode, never throw" rule applied to a value.
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
    @Test("a timeout leaves the outcome unknown")
    func aTimeoutIsUnknown() {
        #expect(AgentStart.isUnknownOutcome(herdr("timeout", "timed out waiting for agent startup")))
    }

    /// Everything else herdr refuses, it refuses **before typing anything** —
    /// each measured under 30ms — so the pane is untouched and a retry is safe.
    @Test("every other refusal happened before anything was typed", arguments: [
        "agent_pane_not_found", "agent_pane_busy", "invalid_agent_name",
        "agent_name_taken", "invalid_agent_timeout",
    ])
    func everythingElseIsARefusal(_ code: String) {
        #expect(!AgentStart.isUnknownOutcome(herdr(code, "refused")))
    }

    @Test("a transport failure is not a herdr timeout")
    func transportIsNotATimeout() {
        #expect(!AgentStart.isUnknownOutcome(TransportError.connectionFailed("closed")))
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

    private func herdr(_ code: String, _ message: String) -> HerdrError {
        HerdrError(
            command: ["agent", "start"], exitCode: 1, stderr: "", code: code, message: message
        )
    }
}
