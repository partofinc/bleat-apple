import Foundation

/// A new terminal for `terminal.run`, as the phone starts one.
///
/// **Always `no_parent` and `no_notify`.** A terminal started over `hc
/// connect` has no parent today, but the parent defaults to the terminal the
/// call comes from, and children end with their parent. Sent explicitly, no
/// change in how `hc` is launched can tie an agent's life to the phone's SSH
/// session or type its exit notes into one (`docs/hc-facts.md`).
///
/// **No terminal identity.** Identity is fixed at start and every terminal
/// the core runs says Ghostty (`TERM=xterm-256color`, `COLORTERM=truecolor`,
/// `TERM_PROGRAM=ghostty`, measured 13 Nov 2026). One started from the phone
/// outlives the phone and is viewed on the Mac too, so it gets the core's
/// identity, the same as every terminal the phone already shows.
///
/// **In Herdr.app only when a space is given.** Herdr.app shows only
/// terminals labeled `herdr.space`; with one, it takes the terminal into that
/// space in a new tab (`HerdrSpace`). Then it also gets `herdr.seen=0`, as
/// herdr-app's `docs/labels.md` says a terminal a client starts does. Never
/// `herdr.tab`: a new tab, not a split beside someone's running agent.
public struct HcRunRequest: Sendable, Equatable {
    public enum Program: Sendable, Equatable {
        /// The host's login shell: `argv: []` starts `$SHELL -l` (live:
        /// `/bin/zsh -l` on a Mac).
        case shell
        /// A shell line, run by the host's `sh -c`.
        case line(String)
        /// One of the host's templates, and the first message for it. The
        /// core starts the template's command and sends its body plus the
        /// task once the agent is ready.
        case template(name: String, task: String)
    }

    public var program: Program
    /// Optional; unique among the host's live terminals.
    public var name: String?
    /// Absolute. Without one the core starts it in its own directory, which
    /// is `/` on a Mac (live), and `~` is not expanded (live: it fails as
    /// "cannot start /bin/sh"). See `HcRunRequest.resolve(directory:home:)`.
    public var cwd: String?
    /// The phone's grid, when it is known, so the program starts at the size
    /// it will be shown at. Without one the core's headless default (200×120)
    /// holds until the phone attaches and takes it over.
    public var size: TerminalGrid?
    /// The Herdr.app space to show it in (`HerdrSpace.id`); none: hidden there.
    public var space: String?

    public init(program: Program, name: String? = nil, cwd: String? = nil, size: TerminalGrid? = nil, space: String? = nil) {
        self.program = program
        self.name = name
        self.cwd = cwd
        self.size = size
        self.space = space
    }

    /// `terminal.run`'s params.
    public var params: [String: HcJSON] {
        var params: [String: HcJSON] = [
            "no_parent": .bool(true),
            "no_notify": .bool(true),
        ]
        switch program {
        case .shell:
            params["argv"] = .array([])
        case .line(let line):
            params["line"] = .string(line)
        case .template(let name, let task):
            let task = task.trimmingCharacters(in: .whitespacesAndNewlines)
            params["argv"] = .array([.string(name)] + (task.isEmpty ? [] : [.string(task)]))
        }
        if let name, !name.isEmpty { params["name"] = .string(name) }
        if let cwd, !cwd.isEmpty { params["cwd"] = .string(cwd) }
        if let size, size.isUsable {
            params["size"] = .object(["cols": .number(Double(size.cols)), "rows": .number(Double(size.rows))])
        }
        if let space, !space.isEmpty {
            params["labels"] = .object(["herdr.space": .string(space), HcSeen.label: .string("0")])
        }
        return params
    }

    /// The new terminal's address in `terminal.run`'s reply (`t64`).
    public static func address(inReply reply: HcJSON) throws -> String {
        guard let address = reply["address"]?.string, !address.isEmpty else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "terminal.run's reply has no address"))
        }
        return address
    }

    /// Whether `name` is one the core accepts: 1–32 of `a-z 0-9 - _ .`
    /// (schema). Checked before sending, so the form can say so as it is typed.
    public static func isValidName(_ name: String) -> Bool {
        (1...32).contains(name.count) && name.allSatisfy { character in
            character.isASCII && (character.isLowercase || character.isNumber || "-_.".contains(character))
        }
    }

    /// An absolute directory from what the user typed: `~` and `~/…` against
    /// the host's home, an absolute path as it is, and anything else relative
    /// to home. Empty is home.
    public static func resolve(directory typed: String, home: String) -> String {
        let typed = typed.trimmingCharacters(in: .whitespaces)
        let home = home.droppingTrailingSlash
        if typed.isEmpty || typed == "~" { return home }
        if typed.hasPrefix("~/") { return home + typed.dropFirst(1) }
        if typed.hasPrefix("/") { return typed }
        return home + "/" + typed
    }
}
