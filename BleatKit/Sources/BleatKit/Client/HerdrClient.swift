import Foundation

/// Typed API over a `HerdrTransport`.
///
/// Reusable after a transport failure: it holds no per-connection state, so the
/// recovery path for a dropped socket is simply to call again on a fresh
/// transport.
public struct HerdrClient: Sendable {
    private let transport: any HerdrTransport
    private let decoder = JSONDecoder()

    public init(transport: any HerdrTransport) {
        self.transport = transport
    }

    // MARK: - Listing

    /// Workspaces, ordered by attention state then by their Herdr number.
    public func workspaces() async throws -> [Workspace] {
        let list: WorkspaceList = try await enveloped(["workspace", "list"])
        return list.workspaces.sorted {
            ($0.agentStatus, $0.number) < ($1.agentStatus, $1.number)
        }
    }

    /// Agents, blocked first. This is the list Bleat's home screen shows.
    ///
    /// `agent list` already carries `cwd`, `pane_id` and `workspace_id`, so no
    /// join against `workspace list` is needed.
    public func agents() async throws -> [Agent] {
        let list: AgentList = try await enveloped(["agent", "list"])
        return list.agents.sortedByAttention()
    }

    public func panes() async throws -> [Pane] {
        let list: PaneList = try await enveloped(["pane", "list"])
        return list.panes
    }

    /// The grid a pane is really rendered on.
    ///
    /// Asked before opening a stream, because `observe --cols` is a viewport
    /// rather than a resize: it crops. Rendering at the phone's width therefore
    /// hides most of a wide pane with nothing on screen to say so, and the only
    /// way to show all of it is to ask for the size it actually has.
    ///
    /// - Parameter target: A full `<workspace>:<pane>` id — `Agent.target`.
    ///   `pane_id` is already that; joining the workspace on again gives
    ///   `w2:w2:p1` and the host answers `pane_not_found`.
    public func paneLayout(target: String) async throws -> PaneLayout {
        let result: PaneLayoutResult = try await enveloped(["pane", "layout", "--pane", target])
        return result.layout
    }

    /// Named sessions on the host.
    ///
    /// Unlike the commands above this one is client-side: it needs an explicit
    /// `--json` and returns an unenveloped payload.
    public func sessions() async throws -> [SessionInfo] {
        let data = try await transport.run(["session", "list", "--json"])
        return try decode(SessionList.self, from: data, command: ["session", "list"]).sessions
    }

    /// Stops a running session.
    ///
    /// **This exits everything in it.** Measured against herdr 0.9.0: stopping
    /// a session killed its pane's shell outright, so on a session holding
    /// agents this is their work ending. Nothing in `BleatKit` can judge
    /// whether that is wanted — `PairedPeer.createdHere` and a confirmation are
    /// what stand between this and a swipe.
    ///
    /// Refused with `session_stop_failed` when the session is not running, so
    /// callers offer it only for one that is.
    ///
    /// - Parameter name: a `SessionName` rather than a `String`, because this
    ///   is a **positional** argument. A session called `-x` — which herdr
    ///   itself will happily create — is parsed as a flag here, and herdr
    ///   answers with its usage line rather than stopping anything.
    @discardableResult
    public func stopSession(named name: SessionName) async throws -> SessionChange {
        let data = try await transport.run(["session", "stop", name.text, "--json"])
        return try decode(SessionChange.self, from: data, command: ["session", "stop"])
    }

    /// Deletes a **stopped** session, and its directory with it.
    ///
    /// herdr refuses this while the session runs (`session_delete_failed`:
    /// "stop it before deleting"), so it is the second of two steps rather
    /// than an alternative to stopping.
    ///
    /// **The reply is not evidence** — see `SessionChange`. Deleting a name
    /// that does not exist answers `{"deleted":true}` and exits 0, so the only
    /// honest confirmation is the session being gone from `session list`.
    @discardableResult
    public func deleteSession(named name: SessionName) async throws -> SessionChange {
        let data = try await transport.run(["session", "delete", name.text, "--json"])
        return try decode(SessionChange.self, from: data, command: ["session", "delete"])
    }

    // MARK: - Creating

    /// Creates a workspace, and with it a tab and one pane running a shell.
    ///
    /// The first thing Bleat makes *inside* someone's session rather than
    /// alongside it. It ends nothing and touches no pane that already exists —
    /// `WorkspaceCreated` records what measuring showed it does produce — but
    /// it is a write on someone else's Mac, so the rules the rest of this file
    /// follows apply.
    ///
    /// - Parameter directory: where the pane opens. A `WorkspaceDirectory`
    ///   rather than a `String` because herdr accepts a path that does not
    ///   exist, and a relative one it resolves against its own working
    ///   directory. Neither is refused and neither is reported.
    /// - Parameter label: what to call it. Omitted when empty, which is not the
    ///   same as sending an empty one: herdr's own default is the basename of
    ///   `directory`, and `WorkspaceDirectory.suggestedLabel` is that same
    ///   string so the field can show what leaving it blank will do.
    ///
    /// **`--no-focus` is passed explicitly**, and it is the one flag here that
    /// is about somebody else. Focusing moves the view of whoever is sitting at
    /// the Mac — the reason `agent focus` is banned outright — and while the
    /// measured default is already not to focus when another workspace holds
    /// it, a default is not a promise. Saying so costs seven characters.
    ///
    /// Measured, and worth knowing before reading a reply: herdr honours it
    /// whenever there is a focus to keep, and **ignores it for the first
    /// workspace in an empty session**, which comes back `focused: true`
    /// whatever is asked. That is not the flag failing — a session with
    /// workspaces has to have one focused — and it is the one case where
    /// focusing takes nothing from anybody, because a moment earlier there was
    /// nothing to focus.
    @discardableResult
    public func createWorkspace(
        in directory: WorkspaceDirectory,
        label: String? = nil
    ) async throws -> WorkspaceCreated {
        var args = ["workspace", "create", "--cwd", directory.path, "--no-focus"]
        if let label, !label.isEmpty { args += ["--label", label] }
        return try await enveloped(args)
    }

    /// Starts a supported agent in a pane that is already at a shell prompt.
    ///
    /// herdr types the kind's executable into the pane and waits for its own
    /// detection to recognise it, so this is a **long call** — measured at 3.5s
    /// warm and 4.9s cold for `claude` over a unix socket, and rather more over
    /// SSH from a phone.
    ///
    /// Everything that can be refused is refused **instantly**, which is what
    /// makes the long one bearable. Measured against herdr 0.9.0, all under
    /// 30ms: `agent_pane_not_found` for a pane that is not there,
    /// `agent_pane_busy` for one already holding an agent *or* merely running
    /// an ordinary command, `invalid_agent_name`, `agent_name_taken`, and
    /// `invalid_agent_timeout`.
    ///
    /// - Parameter timeoutMs: how long herdr waits for the agent to become
    ///   interactive. **Must be greater than 3000 and at most 300000** —
    ///   herdr's own bound, which its `--help` does not mention and which it
    ///   reports as `invalid_agent_timeout`.
    ///
    /// **A timeout does not mean nothing started.** Measured: a `claude` given
    /// a 3.5s budget answered `timed out waiting for agent startup`, and the
    /// pane then held a running, detected claude with `name: null` — herdr
    /// never got to record the name. A caller that reports that as a plain
    /// failure invites a retry, which lands on `agent_pane_busy` because the
    /// pane now holds the agent the user was told had not started. So this
    /// throws and the caller reads the host back; see `AgentStart`.
    @discardableResult
    public func startAgent(
        named name: AgentName,
        kind: AgentKind,
        pane: String,
        timeoutMs: Int = AgentStart.defaultTimeoutMs
    ) async throws -> Agent {
        // The name is positional, like a session's, so it must be a validated
        // type rather than a String: `--kind` would swallow a name that began
        // with a dash. `AgentName` refuses those anyway — herdr requires a
        // lowercase letter first — which is belt and braces the same way
        // `SessionName` is.
        let result: AgentInfoResult = try await enveloped([
            "agent", "start", name.text,
            "--kind", kind.rawValue,
            "--pane", pane,
            "--timeout", String(timeoutMs),
        ])
        return result.agent
    }

    /// One agent row.
    ///
    /// `agents()` would answer the same question, but this screen wants exactly
    /// one pane's `agent_session` and asking the host to enumerate every agent
    /// in the session to find it is work on someone else's Mac.
    public func agent(target: String) async throws -> Agent {
        let result: AgentInfoResult = try await enveloped(["agent", "get", target])
        return result.agent
    }

    /// Blocks until an agent reaches one of `states`, then returns its row.
    ///
    /// A long poll, and the closest thing herdr offers to a push. There is no
    /// stream behind the chat view — `pane read` and the transcript are both
    /// snapshots — so this is what makes it feel live: wait for the agent to
    /// settle, then re-read.
    ///
    /// **A timeout arrives as `HerdrError` with code `timeout`**, exit 1 and the
    /// error envelope on stderr like any other refusal. That is a normal answer
    /// here rather than a failure: it means "still working", and the caller
    /// simply waits again. Without `--timeout` the wait is indefinite, which
    /// would pin an exec channel open forever on a phone that has gone to sleep.
    public func waitForAgent(
        target: String,
        until states: [AgentStatus],
        timeoutMs: Int
    ) async throws -> Agent {
        var args = ["agent", "wait", target, "--timeout", String(timeoutMs)]
        for state in states { args += ["--until", state.rawValue] }
        let result: AgentInfoResult = try await enveloped(args)
        return result.agent
    }

    /// What is running in a pane, so its pty can be found and resized.
    public func paneProcessInfo(target: String) async throws -> PaneProcessInfo {
        let result: PaneProcessInfoResult = try await enveloped(
            ["pane", "process-info", "--pane", target]
        )
        return result.processInfo
    }

    /// A pane's recent output as plain text, for the reader.
    ///
    /// Unlike everything else on this client the payload is **not JSON** and
    /// carries no envelope: `pane read` writes the text straight to stdout. A
    /// failure still arrives the usual way — the error envelope on stderr with
    /// a non-zero exit — so `HerdrError` reaches the caller through the
    /// transport rather than through decoding.
    ///
    /// - Parameter lines: How much scrollback to ask for. The host returns the
    ///   *last* N lines and silently gives fewer when the buffer holds fewer,
    ///   so this is a ceiling rather than a request that can fail. `pane read`
    ///   caps around 1000 lines whatever is asked for.
    public func paneText(target: String, lines: Int = 400) async throws -> [String] {
        let data = try await transport.run([
            "pane", "read", target,
            "--source", "recent-unwrapped",
            "--format", "text",
            "--lines", String(lines),
        ])
        return PaneText.lines(from: data)
    }

    // MARK: - Pane stream

    /// Attach to a pane's live stream.
    ///
    /// - Parameter takeover: Herdr allows one input owner per pane. Pass `true`
    ///   only when the user explicitly asked to seize control.
    public func attach(
        to target: String,
        cols: Int,
        rows: Int,
        takeover: Bool = false
    ) async throws -> any HerdrStream {
        var args = ["terminal", "session", "control", target,
                    "--cols", String(cols), "--rows", String(rows)]
        if takeover { args.append("--takeover") }
        return try await transport.openStream(args)
    }

    /// Attach read-only. Cannot disturb whoever currently holds input.
    public func observe(
        _ target: String,
        cols: Int,
        rows: Int
    ) async throws -> any HerdrStream {
        try await transport.openStream(
            ["terminal", "session", "observe", target,
             "--cols", String(cols), "--rows", String(rows)]
        )
    }

    // MARK: - Contract

    /// Refresh `Fixtures/schema.json`.
    public func schema() async throws -> Data {
        try await transport.run(["api", "schema", "--json"])
    }

    // MARK: - Decoding

    private func enveloped<T: Decodable & Sendable>(_ args: [String]) async throws -> T {
        let data = try await transport.run(args)
        return try decode(HerdrEnvelope<T>.self, from: data, command: args).result
    }

    private func decode<T: Decodable>(
        _ type: T.Type,
        from data: Data,
        command: [String]
    ) throws -> T {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            // A failure here may be an error payload rather than contract drift.
            if let body = try? decoder.decode(HerdrErrorEnvelope.self, from: data) {
                throw HerdrError(
                    command: command,
                    exitCode: 0,
                    stderr: "",
                    code: body.error.code,
                    message: body.error.message
                )
            }
            throw error
        }
    }
}
