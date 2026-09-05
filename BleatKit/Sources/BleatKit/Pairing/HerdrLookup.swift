import Foundation

/// Finds where `herdr` lives on a host.
///
/// The path is deliberately **not** in the pairing QR: baking it in cost 24
/// bytes of modules and went stale the moment herdr moved. The phone resolves
/// it on first connect instead, and stores it on the `PairedPeer`.
///
/// Both ends of the pairing use this — `HostInspector` locally, the enrollment
/// client over SSH — so there is one definition of the question and one of how
/// its answer is read.
public enum HerdrLookup {
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
    public static let command = "${SHELL:-/bin/sh} -lc 'command -v herdr' || true"

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
