import BleatKit
import SwiftUI

/// How a herdr-core terminal's state looks, in the same vocabulary as 1.x's
/// agents (`AgentStatus.symbolName` and `tint`), plus hc's `error`.
extension HcTerminal {
    var symbolName: String {
        switch status?.state {
        case .blocked: "exclamationmark.circle.fill"
        case .error: "xmark.octagon.fill"
        case .working: "circle.dotted"
        case .done: isUnseenDone ? "checkmark.circle.fill" : "checkmark.circle"
        case .idle: "moon.zzz"
        case .other, nil: "terminal"
        }
    }

    var tint: Color {
        switch status?.state {
        case .blocked: .orange
        case .error: .red
        case .working: .blue
        case .done: isUnseenDone ? .green : .secondary
        case .idle, .other, nil: .secondary
        }
    }

    /// Spoken, and the word a row shows nowhere else.
    var stateLabel: String {
        switch status?.state {
        case .blocked: status?.reason.map { "blocked: \($0)" } ?? "blocked"
        case .error: "error"
        case .working: "working"
        case .done: isUnseenDone ? "done, not yet seen" : "done"
        case .idle: "idle"
        case .other(let raw): raw
        case nil: "no status"
        }
    }

    /// The second line: what the program says it is doing, else where it is.
    var detail: String? {
        if let message = status?.msg, !message.isEmpty { return message }
        let path = foreground?.cwd ?? cwd
        guard let path, !path.isEmpty else { return nil }
        return path
    }
}
