/// Identity of the coding-agent session occupying a pane.
///
/// Present on both `agent list` and `pane list` rows. For Claude Code this
/// carries the agent's own session UUID, which is what lets Bleat distinguish
/// two accounts running side by side.
public struct AgentSession: Codable, Sendable, Hashable {
    public let agent: String?
    public let kind: String?
    public let source: String?
    public let value: String?
}
