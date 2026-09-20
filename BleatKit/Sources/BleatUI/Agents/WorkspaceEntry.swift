import BleatKit

/// A row on the workspace screen: an agent, or a pane with no agent in it.
///
/// One list rather than two, because the loading is the same question asked
/// once — `RemoteList` holds the generation token, the cancelled-screen
/// silence and the keep-rows-through-a-refresh rule, and two of them side by
/// side would mean two spinners, two failures and two ways for the screen to
/// be half loaded. The sections are drawn from one answer.
enum WorkspaceEntry: Identifiable, Sendable, Hashable {
    case agent(Agent)
    /// A pane herdr has not recognised an agent in: a plain shell.
    case terminal(Pane)

    /// The pane, which is unique across both kinds — a pane holds an agent or
    /// it does not, so no pane can be in this list twice.
    var id: String {
        switch self {
        case .agent(let agent): agent.paneID
        case .terminal(let pane): pane.paneID
        }
    }

    var agent: Agent? {
        guard case .agent(let agent) = self else { return nil }
        return agent
    }

    var terminal: Pane? {
        guard case .terminal(let pane) = self else { return nil }
        return pane
    }
}
