/// Which agent `herdr agent start` should launch in a pane.
///
/// herdr calls this "supported agent kind and canonical executable", and the
/// value is both: `--kind claude` runs `claude`. The list below is what herdr
/// 0.9.0 offers, read off `agent start --help` on 9 Sept 2026.
///
/// **A string with a known list, not a closed enum.** herdr adds kinds — there
/// were twenty-three on 0.9.0 — and a `Codable` enum would make a host that
/// grew a twenty-fourth undecodable, which is the "unknown keys are ignored,
/// never fatal" rule applied to a value. It also lets a user reach a kind this
/// build has not heard of, which is strictly better than making them wait for
/// an app update to use an agent their herdr already supports.
///
/// **Nothing here checks the binary is installed, and nothing can.** herdr
/// types the executable's name into the pane and waits, so a kind whose binary
/// is missing costs the **full 30-second timeout** and then reports
/// `timed out waiting for agent startup` — with the real cause
/// (`zsh: command not found: devin`) visible only in the pane. Measured. That
/// is why the list is offered as a picker rather than free text, and why
/// `AgentStart` reads the pane back on a timeout.
public struct AgentKind: Sendable, Hashable, Codable, RawRepresentable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }

    /// The kinds herdr 0.9.3 accepts, in the order it lists them.
    ///
    /// The order is herdr's own rather than alphabetical, for the reason
    /// `HerdrClient.agents()` does not re-sort: two orderings of one list is a
    /// way for the app and the host to disagree about something neither of them
    /// decides.
    ///
    /// **`letta` arrived with 0.9.3**, read off `agent start --help` on a live
    /// host — twenty-four now, where 0.9.0 offered twenty-three. Nothing broke
    /// in the meantime, and that is the point of this type being a string with
    /// a known list rather than a closed enum: a kind the app has not heard of
    /// still decodes, and the only cost of being behind is that the picker does
    /// not offer it. Which is exactly what had happened.
    public static let known: [AgentKind] = [
        "pi", "claude", "codex", "gemini", "cursor", "devin", "agy", "cline",
        "omp", "mastracode", "opencode", "copilot", "kimi", "kiro", "droid",
        "amp", "grok", "hermes", "kilo", "qodercli", "qwen", "letta", "maki",
        "muse",
    ].map { AgentKind($0) }

    /// The one this app is named after, and the sensible default on a host that
    /// runs Herdr.
    public static let claude = AgentKind("claude")

    /// Shown in a picker. herdr's own spelling, capitalised only where the
    /// product plainly is — anything else would be inventing branding.
    public var label: String {
        switch rawValue {
        case "claude": "Claude Code"
        case "codex": "Codex"
        case "gemini": "Gemini"
        case "cursor": "Cursor"
        case "copilot": "Copilot"
        case "opencode": "OpenCode"
        case "amp": "Amp"
        case "devin": "Devin"
        case "grok": "Grok"
        case "qwen": "Qwen"
        case "droid": "Droid"
        default: rawValue
        }
    }
}

extension AgentKind: Identifiable {
    public var id: String { rawValue }
}
