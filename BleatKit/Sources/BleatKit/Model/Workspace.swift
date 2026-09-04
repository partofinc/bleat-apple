/// A Herdr workspace, as returned by `herdr workspace list`.
public struct Workspace: Codable, Sendable, Identifiable, Hashable {
    public let workspaceID: String
    public let label: String
    public let number: Int
    public let agentStatus: AgentStatus
    public let focused: Bool
    public let paneCount: Int
    public let tabCount: Int
    public let activeTabID: String?

    public var id: String { workspaceID }

    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case label
        case number
        case agentStatus = "agent_status"
        case focused
        case paneCount = "pane_count"
        case tabCount = "tab_count"
        case activeTabID = "active_tab_id"
    }
}
