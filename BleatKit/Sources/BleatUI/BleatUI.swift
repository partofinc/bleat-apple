import BleatKit
import SwiftUI

/// SwiftUI shared between app targets.
///
/// `BleatKit` stays free of SwiftUI so the transport and domain layers can be
/// linked by things that have no UI at all — the console tool today, an
/// extension or widget later. Views belong here instead.
public enum BleatUI {
    /// Sort order for anything showing agents: attention first.
    ///
    /// Lives here rather than in a view so every list agrees.
    public static func byAttention(_ agents: [Agent]) -> [Agent] {
        agents.sorted { ($0.agentStatus, $0.paneID) < ($1.agentStatus, $1.paneID) }
    }
}

extension AgentStatus {
    /// SF Symbol for a pane's state, used by the agent list and pane header.
    public var symbolName: String {
        switch self {
        case .blocked: "exclamationmark.circle.fill"
        case .working: "circle.dotted"
        case .idle: "moon.zzz"
        case .done: "checkmark.circle"
        case .unknown: "questionmark.circle"
        }
    }

    /// Colour for the same. Blocked is the only one that should read as urgent.
    public var tint: Color {
        switch self {
        case .blocked: .orange
        case .working: .blue
        case .idle: .secondary
        case .done: .green
        case .unknown: .secondary
        }
    }
}
