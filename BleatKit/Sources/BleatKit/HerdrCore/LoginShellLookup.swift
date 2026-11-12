import Foundation

/// Finds where a tool lives on a host, by asking its user's login shell.
///
/// `HerdrCoreLookup` asks it for `hc`. Written for herdr in 1.x, where its
/// measurements were made; the question and the reading of the answer are the
/// same for any tool.
public enum LoginShellLookup {
    /// Asks a **login** shell.
    ///
    /// sshd runs an exec channel through a non-login shell, which reads neither
    /// `.zprofile` nor `.bash_profile` — and that is where Homebrew's `PATH` is
    /// set. Verified: a bare `herdr` over an exec channel answers
    /// `env: herdr: No such file or directory` on a machine where herdr is
    /// plainly installed.
    ///
    /// `${SHELL:-/bin/sh}` rather than a fixed shell: `-lc` means different
    /// startup files per shell, and the one that has the user's `PATH` is
    /// theirs. sshd sets `SHELL` from the passwd entry, but the fallback costs
    /// nothing and covers an environment that does not.
    /// The trailing `|| true` is load-bearing. `command -v` exits 1 when it
    /// finds nothing, and the login shell exits with it, so over an exec
    /// channel a host without herdr produces a *failed command* rather than an
    /// empty answer — and the caller reports `the host rejected a command
    /// (exit 1)` instead of "herdr is not installed on that host". Absence is a
    /// normal answer to this question, so it is spelled as empty output.
    ///
    /// `tool` is interpolated into single quotes, so it must be a plain name
    /// with no quote or space; every caller passes a literal.
    public static func command(locating tool: String) -> String {
        "${SHELL:-/bin/sh} -lc 'command -v \(tool)' || true"
    }

    /// Reads the answer out of the shell's output.
    ///
    /// A login shell sources the user's profile, and profiles print things — a
    /// banner, a motd, an nvm notice, a version-manager warning. Taking the
    /// whole of stdout would store `"Welcome back!\n/opt/homebrew/bin/herdr"`
    /// as the path and fail at the first herdr call with an opaque error.
    /// `command -v` answers last, so the last line is the answer.
    ///
    /// The leading `/` is required: `command -v` also answers with shell
    /// builtins and functions by name, and a relative answer is not something
    /// a later non-login shell could resolve anyway.
    public static func path(inOutput output: String) -> String? {
        let candidate = output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
        guard let candidate, candidate.hasPrefix("/") else { return nil }
        return candidate
    }
}
