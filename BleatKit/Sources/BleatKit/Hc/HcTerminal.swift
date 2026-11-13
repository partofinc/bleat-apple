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
        return programName ?? address
    }

    /// What runs in it, as a person would type it: the foreground's first
    /// word, else the one it was started with, as a last path component with
    /// a login shell's leading `-` dropped (`-zsh` is `zsh`). Nil when
    /// neither is known.
    ///
    /// One definition for the row's name and the new-terminal form's
    /// suggestions, so a terminal the list calls `claude` is suggested as
    /// `claude`.
    public var programName: String? {
        let first = [foreground?.argv?.first, argv?.first].compactMap { $0 }.first { !$0.isEmpty }
        guard let first else { return nil }
        let program = (first as NSString).lastPathComponent
        let trimmed = program.hasPrefix("-") ? String(program.dropFirst()) : program
        return trimmed.isEmpty ? nil : trimmed
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

extension Sequence<HcTerminal> {
    /// Most urgent first; ties in address order, `t9` before `t10`.
    ///
    /// Here in `BleatKit` rather than in a view, so the app's list and `bleat
    /// terminals` cannot disagree about it.
    public func sortedByAttention() -> [HcTerminal] {
        sorted { lhs, rhs in
            guard lhs.attention == rhs.attention else { return lhs.attention < rhs.attention }
            return lhs.address.precedesAsTarget(rhs.address)
        }
    }
}

extension String {
    /// Address order, numbers compared as numbers: `t9` before `t10`.
    func precedesAsTarget(_ other: String) -> Bool {
        compare(other, options: [.numeric]) == .orderedAscending
    }
}
