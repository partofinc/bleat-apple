/// A terminal pane, from `herdr pane list`.
///
/// Overlaps `Agent` heavily; a pane row exists whether or not an agent was
/// recognized in it, and adds scroll position.
public struct Pane: Codable, Sendable, Identifiable, Hashable {
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
    public let scroll: PaneScroll?

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
        case scroll
    }
}

/// Scrollback position for a pane.
public struct PaneScroll: Codable, Sendable, Hashable {
    public let offsetFromBottom: Int?
    public let maxOffsetFromBottom: Int?
    public let viewportRows: Int?

    enum CodingKeys: String, CodingKey {
        case offsetFromBottom = "offset_from_bottom"
        case maxOffsetFromBottom = "max_offset_from_bottom"
        case viewportRows = "viewport_rows"
    }
}
