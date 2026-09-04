/// A recognized coding agent occupying a pane, from `herdr agent list`.
public struct Agent: Codable, Sendable, Identifiable, Hashable {
    public let paneID: String
    public let workspaceID: String
    public let tabID: String
    public let terminalID: String?
    public let agent: String?
    public let agentStatus: AgentStatus
    public let agentSession: AgentSession?
    public let cwd: String?
    public let foregroundCwd: String?
    public let focused: Bool
    public let terminalTitle: String?
    public let terminalTitleStripped: String?
    public let revision: Int?
    public let stateChangeSeq: Int?

    /// Pane targets are addressed as `workspace:pane`, e.g. `w2:p1`.
    public var id: String { paneID }

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case workspaceID = "workspace_id"
        case tabID = "tab_id"
        case terminalID = "terminal_id"
        case agent
        case agentStatus = "agent_status"
        case agentSession = "agent_session"
        case cwd
        case foregroundCwd = "foreground_cwd"
        case focused
        case terminalTitle = "terminal_title"
        case terminalTitleStripped = "terminal_title_stripped"
        case revision
        case stateChangeSeq = "state_change_seq"
    }
}
