import Foundation

/// One line on a subscription's channel (live, hc 0.1.20).
public enum HcNotification: Sendable, Equatable {
    /// `{type, terminal, seq, data}`: hand it to `HcTerminalSet.apply(event:)`.
    case event(HcJSON)
    /// The subscriber fell behind; a fresh `{seq, terminals}` replaces the
    /// backlog.
    case missed(HcJSON)
    /// Every 15 s, carrying the current `seq`.
    case heartbeat
    /// A method this build does not know. Skipped, never fatal.
    case other(String)
}

extension HcNotification {
    init(_ message: HcJSON) {
        let params = message["params"] ?? .null
        switch message["method"]?.string {
        case "event": self = .event(params)
        case "missed": self = .missed(params)
        case "heartbeat": self = .heartbeat
        case let other: self = .other(other ?? "")
        }
    }
}
