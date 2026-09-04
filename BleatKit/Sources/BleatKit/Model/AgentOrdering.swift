import Foundation

extension Sequence<Agent> {
    /// The one ordering for agents: attention state first, then pane target.
    ///
    /// This is the single source of truth. `HerdrClient` returns lists in this
    /// order and any view that re-sorts must call the same thing — two copies
    /// of the comparator drift the moment the rank order changes.
    public func sortedByAttention() -> [Agent] {
        sorted { lhs, rhs in
            guard lhs.agentStatus == rhs.agentStatus else {
                return lhs.agentStatus < rhs.agentStatus
            }
            return lhs.paneID.precedesAsTarget(rhs.paneID)
        }
    }
}

extension String {
    /// Orders pane targets the way a person reads them: `w1:p2` before `w1:p10`.
    ///
    /// Plain string ordering puts `p10` before `p2`, so any workspace that
    /// reaches ten panes lists them wrong. The ids are opaque — `w2` and
    /// `w653998617a6031` both occur — so this cannot parse a number out of
    /// them; comparing digit runs numerically handles both shapes.
    func precedesAsTarget(_ other: String) -> Bool {
        compare(other, options: [.numeric]) == .orderedAscending
    }
}
