/// Attention state Herdr reports for a pane or workspace.
///
/// Verified values from `agent list` / `workspace list` on herdr 0.8.2.
/// Unknown values decode to `.unknown` rather than failing: the contract says
/// unrecognized data is never fatal.
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

    /// Sort weight for the UI: blocked → working → idle → done → unknown.
    public var attentionRank: Int {
        switch self {
        case .blocked: 0
        case .working: 1
        case .idle: 2
        case .done: 3
        case .unknown: 4
        }
    }
}

extension AgentStatus: Comparable {
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.attentionRank < rhs.attentionRank
    }
}
