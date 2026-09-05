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

    /// Public because the type is decoded from the host in production and
    /// constructed by hand in tests and previews; a `Codable` struct's
    /// memberwise initialiser is internal.
    public init(
        workspaceID: String,
        label: String,
        number: Int,
        agentStatus: AgentStatus,
        focused: Bool = false,
        paneCount: Int = 1,
        tabCount: Int = 1,
        activeTabID: String? = nil
    ) {
        self.workspaceID = workspaceID
        self.label = label
        self.number = number
        self.agentStatus = agentStatus
        self.focused = focused
        self.paneCount = paneCount
        self.tabCount = tabCount
        self.activeTabID = activeTabID
    }

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
