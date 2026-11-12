import Foundation

/// What a program reports about itself (OSC 7501), kept by hc as reported.
public struct HcStatus: Sendable, Equatable, Decodable {
    public enum State: Sendable, Equatable, Decodable {
        case idle, working, done, blocked, error
        /// A state this build does not know. Decoded, never fatal.
        case other(String)

        public init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            switch raw {
            case "idle": self = .idle
            case "working": self = .working
            case "done": self = .done
            case "blocked": self = .blocked
            case "error": self = .error
            default: self = .other(raw)
            }
        }
    }

    /// Optional so a report without one still decodes: a status that cannot
    /// be read must not cost the whole terminal list.
    public let state: State?
    /// The reporting program, e.g. `claude-code`.
    public let app: String?
    /// Its one-line summary of what it is doing or did.
    public let msg: String?
    /// Why it is blocked: `permission`, `question`, `auth`.
    public let reason: String?
    /// 0–100, while working or blocked.
    public let progress: Double?
}
