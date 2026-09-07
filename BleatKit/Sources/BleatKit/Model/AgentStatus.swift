/// Attention state Herdr reports for a pane or workspace.
///
/// Verified values from `agent list` / `workspace list` on herdr 0.8.2. All
/// five have now been captured live; see `Fixtures/agent-list-blocked.json`
/// and `Fixtures/agent-list-done.json`. Unknown values decode to `.unknown`
/// rather than failing: the contract says unrecognized data is never fatal.
public enum AgentStatus: String, Codable, Sendable, CaseIterable {
    case working
    case blocked
    case done
    case idle
    case unknown

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AgentStatus(rawValue: raw) ?? .unknown
    }

    /// Sort weight for the UI: blocked → done → working → idle → unknown.
    ///
    /// **`done` outranks `idle`, and that is not the order this file used to
    /// state.** Herdr's own definition, read off `herdr --skill` on 7 Sept
    /// 2026, is that `done` "is the same underlying idle state after unseen
    /// background work finishes" — so the two differ by exactly one thing,
    /// whether anybody has looked. `idle` is ready *and seen*; `done` is
    /// finished *and unseen*, which is the whole reason a phone is in the
    /// user's hand. Ranking it last put the one row worth opening below every
    /// agent that had already been dealt with.
    ///
    /// It sits above `working` for the same reason `blocked` does: both are
    /// waiting on a person, while a working agent is making progress without
    /// one. Verified live that the distinction is real and that Bleat can
    /// observe it — `agent focus` collapses `done` back to `idle`, and a CLI
    /// read does not, which is why nothing in this app calls focus.
    public var attentionRank: Int {
        switch self {
        case .blocked: 0
        case .done: 1
        case .working: 2
        case .idle: 3
        case .unknown: 4
        }
    }
}

extension AgentStatus: Comparable {
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.attentionRank < rhs.attentionRank
    }
}
