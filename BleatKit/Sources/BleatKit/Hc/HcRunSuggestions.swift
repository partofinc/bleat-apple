import Foundation

/// What to offer when starting a terminal, read from the ones already running.
///
/// A host's terminals are the best guess at where its work is and what runs
/// there: the directories its terminals sit in, and the programs (an agent's
/// `claude`, `codex`) running in them. Nothing is stored; it is read off the
/// list each time.
public enum HcRunSuggestions {
    /// Directories the host's terminals are in, most used first. The
    /// foreground's directory where there is one, since that is where the
    /// work is; the terminal's own otherwise.
    public static func directories(from terminals: [HcTerminal], excluding home: String? = nil) -> [String] {
        let all = terminals.compactMap { $0.foreground?.cwd ?? $0.cwd }.filter { $0.hasPrefix("/") && $0 != "/" && $0 != home }
        return ranked(all)
    }

    /// Programs running in the host's terminals, most used first, as the
    /// command a user would type: the first word's last path component.
    /// Shells are left out: "Shell" is already its own choice.
    public static func commands(from terminals: [HcTerminal]) -> [String] {
        let all = terminals.compactMap { terminal -> String? in
            guard let first = (terminal.foreground?.argv ?? terminal.argv)?.first else { return nil }
            let command = (first as NSString).lastPathComponent.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            return command.isEmpty || shells.contains(command) ? nil : command
        }
        return ranked(all)
    }

    /// `~/x` for a path under `home`, for showing; the path as it is otherwise.
    public static func abbreviate(_ path: String, home: String?) -> String {
        guard let home, !home.isEmpty, home != "/" else { return path }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    static let shells: Set<String> = ["sh", "bash", "zsh", "fish", "dash", "ksh", "tcsh", "csh", "nu", "login"]

    private static func ranked(_ values: [String]) -> [String] {
        var counts: [String: Int] = [:]
        for value in values { counts[value, default: 0] += 1 }
        return counts.keys.sorted { counts[$0]! == counts[$1]! ? $0 < $1 : counts[$0]! > counts[$1]! }
    }
}
