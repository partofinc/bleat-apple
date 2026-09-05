import Foundation

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

    /// The pane's target, as every `terminal session` command spells it.
    public var target: String { "\(workspaceID):\(paneID)" }

    /// What to call this agent on screen.
    ///
    /// Herdr offers three names and each can be missing or empty: the stripped
    /// terminal title (already free of escape sequences), the raw one, and the
    /// agent's own kind. The last resort is the pane id, which is at least
    /// unique — an untitled row is otherwise indistinguishable from every other
    /// untitled row, and both the app and the console tool list these together.
    public var displayTitle: String {
        for candidate in [terminalTitleStripped, terminalTitle, agent] {
            if let candidate, !candidate.trimmingCharacters(in: .whitespaces).isEmpty {
                return candidate
            }
        }
        return paneID
    }

    /// Public for tests and previews; a `Codable` struct's memberwise
    /// initialiser is internal. Everything the host may omit has a default, so
    /// a caller states only what it means to say.
    public init(
        paneID: String,
        workspaceID: String,
        tabID: String,
        agentStatus: AgentStatus,
        terminalID: String? = nil,
        agent: String? = nil,
        agentSession: AgentSession? = nil,
        cwd: String? = nil,
        foregroundCwd: String? = nil,
        focused: Bool = false,
        terminalTitle: String? = nil,
        terminalTitleStripped: String? = nil,
        revision: Int? = nil,
        stateChangeSeq: Int? = nil
    ) {
        self.paneID = paneID
        self.workspaceID = workspaceID
        self.tabID = tabID
        self.terminalID = terminalID
        self.agent = agent
        self.agentStatus = agentStatus
        self.agentSession = agentSession
        self.cwd = cwd
        self.foregroundCwd = foregroundCwd
        self.focused = focused
        self.terminalTitle = terminalTitle
        self.terminalTitleStripped = terminalTitleStripped
        self.revision = revision
        self.stateChangeSeq = stateChangeSeq
    }

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
