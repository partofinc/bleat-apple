import Foundation

/// Asking the host where a directory really is, before a workspace is made in
/// it.
///
/// **Two questions, and it has to be one command, because the answers have to
/// agree.** herdr will neither refuse a directory that is not there nor report
/// the path it was given:
///
/// - `workspace create --cwd /no/such/dir` exits 0, answers
///   `workspace_created`, and opens the pane in the home directory instead.
/// - the cwd it reports back is **canonical**. Measured against herdr 0.9.0,
///   and again on 0.9.3 — where a *symlinked* `--cwd` was resolved to its
///   real path, and to the same answer `cd … && pwd -P` gives, which is what
///   this check relies on:
///   `/tmp` comes back `/private/tmp`, `/var` comes back `/private/var`,
///   `/Users/robin//Developer` and `/Users/robin/Developer/../Developer` both
///   come back `/Users/robin/Developer`.
///
/// So a phone that asked for `/tmp` and compared herdr's answer to what it
/// typed would conclude the workspace had gone somewhere else — about a
/// workspace created exactly where it was asked for. `cd … && pwd -P` is the
/// same resolution herdr does, so asking for it up front settles both: a path
/// that cannot be entered has no answer, and the one that comes back is the
/// form herdr will report.
///
/// Plain shell rather than a herdr command, so it goes through
/// `ConnectionStore.shell` and leaves the session prefix alone, exactly as the
/// pairing commands do.
public enum DirectoryCheck {
    /// Prefixes the one line worth reading. Deliberately unlikely to occur in a
    /// login shell's own output.
    static let prefix = "bleat-dir-at:"

    /// - Returns: a command that exits 0 whatever the answer, and prints
    ///   `bleat-dir-at:<resolved path>` — with nothing after the colon when the
    ///   path is not a directory that can be entered.
    ///
    /// **Exit status cannot carry the answer**, and that is not a style choice:
    /// `ShellRunner.run` throws `ShellError` on a non-zero exit, so a bare
    /// `test -d` would reach the caller as "the host rejected a command (exit
    /// 1)" about a host that answered the question perfectly well. The same
    /// reason `HerdrLookup.command` ends in `|| true`.
    ///
    /// **`cd`'s own output is redirected inside the substitution**, so a `chpwd`
    /// hook — an `ls` on every directory change is a common one — cannot get
    /// into the captured value and be mistaken for the path.
    public static func command(for directory: WorkspaceDirectory) -> String {
        "printf '\(prefix)%s\\n' \"$(cd \(quote(directory.path)) >/dev/null 2>&1 && pwd -P)\""
    }

    /// The directory's real path, or nil when the host could not enter it.
    ///
    /// nil covers every way of not being a usable directory at once — missing,
    /// a file, or unreadable — because `cd` refuses all three and the remedy
    /// the user needs is the same. Verified against a login shell: `/etc/hosts`
    /// and `/no/such/dir` both answer with an empty value.
    ///
    /// **A prefixed line, never the whole of stdout.** sshd runs an exec
    /// command through a login shell, `.zshenv` is sourced for every
    /// non-interactive zsh, and profiles print banners — `PeerConnector` had a
    /// `printf ok` probe that any of that defeated. Comparing exactly would
    /// refuse every directory on a Mac with a chatty profile.
    ///
    /// Absence is the default answer: a reply carrying no such line at all is
    /// not evidence that the directory exists, and creating a workspace is the
    /// side that should need proof.
    public static func resolvedPath(inOutput output: String) -> String? {
        guard let line = output
            .split(separator: "\n", omittingEmptySubsequences: false)
            .last(where: { $0.hasPrefix(prefix) })
        else { return nil }
        let path = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        // `pwd -P` is absolute by construction, so anything else is a shell
        // that answered with something other than a path.
        return path.hasPrefix("/") ? path : nil
    }

    /// Single quotes for POSIX shells, the same rule as `SSHTransport.quote`.
    ///
    /// Not redundant with the transport's own quoting: this string is the whole
    /// command rather than an argument, so it reaches `run(shell:)` already
    /// assembled and nothing else will quote the path inside it. A path is
    /// arbitrary user text and may hold a space or a quote.
    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
