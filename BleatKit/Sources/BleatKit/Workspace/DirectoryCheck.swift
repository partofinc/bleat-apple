import Foundation

/// Asking the host whether a directory is really there, before a workspace is
/// made in it.
///
/// **herdr will not do this for you.** `workspace create --cwd /no/such/dir`
/// exits 0, answers `workspace_created`, and opens the pane in the home
/// directory instead — see `WorkspaceDirectory`. Without this check the phone's
/// only options are to report a success that is wrong about where the
/// workspace is, or to report the mistake *after* having made one on someone
/// else's Mac. One round trip beforehand turns both into a refusal.
///
/// Plain shell rather than a herdr command, so it goes through
/// `ConnectionStore.shell` and leaves the session prefix alone, exactly as the
/// pairing commands do.
public enum DirectoryCheck {
    /// Printed when the directory is there. Deliberately unlikely to occur in a
    /// login shell's own output.
    static let present = "bleat-dir-present"
    static let absent = "bleat-dir-absent"

    /// - Returns: a command that exits 0 either way and says which in its
    ///   output.
    ///
    /// **Exit status cannot carry the answer**, and that is not a style
    /// choice: `ShellRunner.run` throws `ShellError` on a non-zero exit, so a
    /// bare `test -d` would reach the caller as "the host rejected a command
    /// (exit 1)" about a host that answered the question perfectly well. The
    /// same reason `HerdrLookup.command` ends in `|| true`.
    public static func command(for directory: WorkspaceDirectory) -> String {
        "test -d \(quote(directory.path)) && echo \(present) || echo \(absent)"
    }

    /// Whether the host said the directory is there.
    ///
    /// **A token in the output, never the whole of it.** `sshd` runs an exec
    /// command through a login shell, profiles print banners, and `.zshenv` is
    /// sourced for every non-interactive zsh — so comparing stdout exactly is
    /// how a working host is reported as broken. `PeerConnector` learned this
    /// with a `printf ok` probe that any startup banner defeated; the same
    /// mistake here would refuse every directory on a Mac with a chatty
    /// profile.
    ///
    /// Absence is the default answer: a reply that says neither is not
    /// evidence that the directory exists, and creating a workspace is the
    /// side that should need proof.
    public static func exists(inOutput output: String) -> Bool {
        output.contains(present)
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
