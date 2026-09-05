import Foundation

/// Socket-API commands (`workspace list`, `agent list`, `pane list`, …) wrap
/// their payload as `{"id": "cli:workspace:list", "result": {…}}`.
///
/// Client-side commands such as `session list --json` are *not* enveloped, so
/// decode those against the bare payload instead.
public struct HerdrEnvelope<Result: Decodable & Sendable>: Decodable, Sendable {
    public let id: String?
    public let result: Result
}

/// Error payload: `{"error": {"code": …, "message": …}}`.
public struct HerdrErrorEnvelope: Decodable, Sendable {
    public let error: HerdrErrorBody
}

public struct HerdrErrorBody: Decodable, Sendable {
    public let code: String
    public let message: String
}

// MARK: - Result payloads

public struct WorkspaceList: Decodable, Sendable {
    public let workspaces: [Workspace]
}

public struct AgentList: Decodable, Sendable {
    public let agents: [Agent]
}

/// `pane layout`'s payload. The layout is one level down, beside a `type`.
public struct PaneLayoutResult: Decodable, Sendable {
    public let layout: PaneLayout
}

public struct PaneList: Decodable, Sendable {
    public let panes: [Pane]
}

/// `session list --json` — no envelope.
public struct SessionList: Decodable, Sendable {
    public let sessions: [SessionInfo]
}
