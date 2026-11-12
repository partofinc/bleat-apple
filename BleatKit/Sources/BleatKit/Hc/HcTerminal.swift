import Foundation

/// One terminal on a herdr-core host, as `terminal.list` and the event
/// snapshot report it.
///
/// Derived from live replies (hc 0.1.20, `Fixtures/hc-subscribe.json`), not
/// invented: every field is optional but `address`, because a record from an
/// older or newer core may lack any of them, and unknown keys are ignored.
public struct HcTerminal: Sendable, Equatable, Identifiable, Decodable {
    /// `t58` here, `adam/t8` for a terminal mirrored from a federated machine.
    public let address: String
    public let name: String?
    /// The program's own title (OSC 0/2). Often empty.
    public let title: String?
    public let cwd: String?
    /// `live` or `finished`.
    public let state: String?
    public let status: HcStatus?
    /// Goes up each time the terminal's root record leaves `working`.
    public let turn: Int?
    public let labels: [String: String]?
    public let cols: Int?
    public let rows: Int?
    public let argv: [String]?
    public let foreground: Foreground?
    public let exitCode: Int?

    public struct Foreground: Sendable, Equatable, Decodable {
        public let argv: [String]?
        public let cwd: String?
        public let name: String?
    }

    enum CodingKeys: String, CodingKey {
        case address, name, title, cwd, state, status, turn, labels, cols, rows, argv, foreground
        case exitCode = "exit_code"
    }

    public var id: String { address }

    /// On the host Bleat connected to, rather than mirrored from another
    /// machine that host federates. Bleat pairs those machines directly, so
    /// showing their mirrors too would list them twice.
    public var isLocal: Bool { !address.contains("/") }

    public var isLive: Bool { state == "live" }

    /// The `where` label Herdr.app writes: `"nuvio-health / Agent"`, space then
    /// tab. Nil on a host whose terminals Herdr.app never touched — a Pi, the
    /// demo host.
    public var location: (space: String, tab: String?)? {
        guard let value = labels?["where"]?.trimmingCharacters(in: .whitespaces), !value.isEmpty else {
            return nil
        }
        guard let split = value.range(of: " / ") else { return (value, nil) }
        return (String(value[..<split.lowerBound]), String(value[split.upperBound...]))
    }

    /// The last turn someone looked at, as Herdr.app records it in
    /// `herdr.seen` (live: `herdr.seen: "16"` beside `turn: 16` on a `done`
    /// terminal that had been read).
    public var seenTurn: Int? { labels?["herdr.seen"].flatMap { Int($0) } }

    /// `done`, and nobody has looked since the turn ended. hc never clears
    /// `done` itself; this is the reading Herdr.app gives it.
    public var isUnseenDone: Bool {
        guard status?.state == .done else { return false }
        guard let turn, let seen = seenTurn else { return true }
        return seen < turn
    }

    /// A name for a row. The program's title when it set one; then the name it
    /// was started with; then what it is running.
    ///
    /// Not `foreground.name`: for Claude Code that reads `2.1.322`, its version.
    public var displayName: String {
        if let title, !title.isEmpty { return title }
        if let name, !name.isEmpty { return name }
        let program = foreground?.argv?.first ?? argv?.first
        if let program { return (program as NSString).lastPathComponent }
        return address
    }

    /// How urgently this terminal wants a person, lowest first.
    public var attention: Int {
        switch status?.state {
        case .blocked, .error: 0
        case .done where isUnseenDone: 1
        case .working: 2
        case .done, .idle: 3
        case .other: 4
        case nil: 5
        }
    }
}

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

extension Sequence<HcTerminal> {
    /// Most urgent first; ties in address order, `t9` before `t10`.
    public func sortedByAttention() -> [HcTerminal] {
        sorted { lhs, rhs in
            guard lhs.attention == rhs.attention else { return lhs.attention < rhs.attention }
            return lhs.address.precedesAsTarget(rhs.address)
        }
    }
}
