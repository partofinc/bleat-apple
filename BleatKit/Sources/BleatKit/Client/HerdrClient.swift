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
