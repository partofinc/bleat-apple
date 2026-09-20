import Foundation

extension Sequence<Pane> {
    /// The panes with no agent in them: the plain shells.
    ///
    /// A pane is a shell until herdr recognises an agent in it — `workspace
    /// create` and `tab create` take no command, so what launches is the user's
    /// own shell and an agent is a separate, explicit step. Those panes are
    /// invisible to `agent list`, which is why the screen that lists agents has
    /// to ask for `pane list` as well.
    ///
    /// **Occupancy is read from the agent list, never from a pane's own
    /// fields**, which is the rule `NewAgentModel` already follows when it
    /// offers a pane to start an agent in: both lists come from the host, and
    /// the agent list is the one that decides. It is also the one that covers
    /// the awkward row — a start that timed out leaves a detected agent that
    /// herdr never got to name, and `agent list` reports it while its `name` is
    /// null. Such a pane is somebody's agent, not a free terminal.
    ///
    /// Ordered like the agents above them, so `w1:p2` comes before `w1:p10`.
    public func withoutAgents(in agents: [Agent]) -> [Pane] {
        let occupied = Set(agents.map(\.paneID))
        return filter { !occupied.contains($0.paneID) }
            .sorted { $0.paneID.precedesAsTarget($1.paneID) }
    }
}
