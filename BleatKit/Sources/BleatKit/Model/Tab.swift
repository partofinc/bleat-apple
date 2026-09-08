/// A tab inside a workspace.
///
/// The level between a workspace and its panes, and the one the app has never
/// had to name before: `agent list` and `pane list` both carry `tab_id` on
/// every row, so nothing needed a tab of its own to read. Creating a workspace
/// is what produces one — see `WorkspaceCreated`.
///
/// Almost everything is optional, for the reason `PaneLayout`'s fields are:
/// nothing in the app reads a tab yet, and a decode failure on a field with no
/// caller would throw away a workspace that was created perfectly well.
public struct Tab: Codable, Sendable, Identifiable, Hashable {
    public let tabID: String
    public let workspaceID: String
    /// herdr's own default is the tab's number as a string — `"1"` — rather
    /// than anything descriptive.
    public let label: String?
    public let number: Int?
    public let agentStatus: AgentStatus?
    public let focused: Bool?
    public let paneCount: Int?

    public var id: String { tabID }

    public init(
        tabID: String,
        workspaceID: String,
        label: String? = nil,
        number: Int? = nil,
        agentStatus: AgentStatus? = nil,
        focused: Bool? = nil,
        paneCount: Int? = nil
    ) {
        self.tabID = tabID
        self.workspaceID = workspaceID
        self.label = label
        self.number = number
        self.agentStatus = agentStatus
        self.focused = focused
        self.paneCount = paneCount
    }

    enum CodingKeys: String, CodingKey {
        case tabID = "tab_id"
        case workspaceID = "workspace_id"
        case label
        case number
        case agentStatus = "agent_status"
        case focused
        case paneCount = "pane_count"
    }
}
