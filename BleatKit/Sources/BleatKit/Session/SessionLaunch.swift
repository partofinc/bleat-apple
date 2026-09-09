import Foundation

/// Starting a named Herdr session on a host.
///
/// **`herdr session attach <name>`, run with no pty.** There is still no
/// `session create` on 0.9.0 — `herdr session` offers only `list`, `attach`,
/// `stop`, `delete` — and `attach` is the one that brings a session into being.
///
/// This file used to say the opposite, and used `herdr server` behind a
/// `nohup … &` with a log file, because `attach` "is the TUI, so it wants a pty,
/// and the pty it gets becomes the session's geometry". The second half is true
/// **only when there is a pty**. Over an SSH exec channel there is none, so the
/// hazard cannot arise, and the reasoning that built the old command was never
/// measured. It has been now.
///
/// Measured against herdr 0.9.0, 9 Sept 2026, over a real SSH exec channel
/// (throwaway sshd on 127.0.0.1:2222, no pty, no `HERDR_*` in the environment,
/// login shell `zsh`):
///
/// | | |
/// |---|---|
/// | session created, server reparented to pid 1 | yes |
/// | the server's stdin/stdout/stderr | **all `/dev/null`** |
/// | channel returned in | 0.14s |
/// | pane geometry | **120×40**, the headless default |
/// | second launch while running | same pid, no error, no second server |
/// | on a stopped session | resumes it, with the workspaces it had |
///
/// So herdr daemonises the server itself. `nohup`, `&`, the stdout redirect and
/// the log file it wrote to were all defending against something herdr had
/// already done — and the log brought a `${TMPDIR:-$HOME}` fallback with it,
/// which existed only because a predictable name under a world-writable `/tmp`
/// is a symlink that this redirect would truncate as the SSH user. All of it is
/// gone.
///
/// Three things the caller still has to live with:
///
/// - **Success exits 1.** The TUI cannot draw without a pty, so it prints
///   `herdr: Inappropriate ioctl for device (os error 25)` and exits 1 *after*
///   the server is up. That is the ordinary headless path, which is why the
///   command ends in `|| true` — without it `ShellRunner.run` throws on every
///   successful start. **Never show that text to the user.**
/// - **A refusal exits 2** and says why, on stderr, synchronously — a real
///   improvement on the old command, whose status was the shell's and therefore
///   meant nothing at all. `diagnosis(inLaunchOutput:)` reads it.
/// - **The launch is still checked, not trusted.** Exit 1 cannot tell "server
///   up, TUI could not draw" from "TUI could not draw for another reason", so
///   `SessionStarter` still reads `session list` back. That rule was never
///   about `herdr server` specifically.
public enum SessionLaunch {

    /// Starts `name` on the host and returns as soon as the server is up.
    ///
    /// - Parameter herdrPath: Absolute, from the `PairedPeer`. A non-login
    ///   shell usually has no `herdr` on `PATH`.
    public static func startCommand(name: SessionName, herdrPath: String) -> String {
        // `-u HERDR_SOCKET_PATH` for the reason `SSHTransport.command` clears
        // it: a socket path leaking in from the environment pins the command to
        // a different session. `-u HERDR_SESSION` is new and belongs with it —
        // the name is a positional argument now rather than an environment
        // variable, and an inherited one would make which session gets started
        // depend on the login profile. Measured clean over SSH; this is for the
        // host whose profile exports them.
        //
        // `</dev/null` because the TUI reads stdin, and `2>&1` because herdr's
        // refusal goes to stderr and is the only account of it there will be.
        //
        // `|| true` for the reason `HerdrLookup.command` has one: the ordinary
        // outcome here is a non-zero status. Exit 1 *is* the success path.
        "env -u HERDR_SOCKET_PATH -u HERDR_SESSION \(quote(herdrPath)) "
            + "session attach \(quote(name.text)) </dev/null 2>&1 || true"
    }

    /// herdr's own account of why a launch produced no session, or nil.
    ///
    /// The same rule `AgentStart.diagnosis` follows and for the same reason:
    /// **never guess**. A launch that worked writes
    /// `herdr: Inappropriate ioctl for device` and nothing else, and offering
    /// that to a user under the heading "that did not happen" would be herdr
    /// reporting a success as the reason for a failure. Only a line herdr
    /// prefixes `error: ` is a cause.
    ///
    /// **The ANSI is stripped first, and that is measured rather than
    /// defensive.** herdr styles some of its own errors even when stderr is not
    /// a terminal — captured to a file, the nested-herdr refusal arrives as
    /// `ESC[1merror:ESC[0m nested herdr is disabled by default`, which no
    /// prefix test on the raw bytes can match. The old code tested the raw line
    /// and would have reported that one as "no cause given".
    ///
    /// - Parameter output: stdout and stderr of `startCommand`, merged.
    public static func diagnosis(inLaunchOutput output: String) -> String? {
        output
            .split(separator: "\n", omittingEmptySubsequences: false)
            .lazy
            .map { stripANSI(String($0)).trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { $0.hasPrefix(errorPrefix) }
            .map { String($0.dropFirst(errorPrefix.count)) }
    }

    private static let errorPrefix = "error: "

    /// Drops CSI sequences (`ESC[…final`) and lone escapes.
    ///
    /// Deliberately narrow: this reads a diagnostic, so anything it does not
    /// recognise must survive into the message rather than being eaten.
    private static func stripANSI(_ text: String) -> String {
        var out = ""
        var rest = Substring(text)
        while let esc = rest.firstIndex(of: "\u{1B}") {
            out += rest[rest.startIndex..<esc]
            var scan = rest.index(after: esc)
            // CSI: `[` then parameter and intermediate bytes, then a final byte
            // in @-~. Anything else is a lone escape and is simply dropped.
            if scan < rest.endIndex, rest[scan] == "[" {
                scan = rest.index(after: scan)
                while scan < rest.endIndex, !("\u{40}"..."\u{7E}").contains(rest[scan]) {
                    scan = rest.index(after: scan)
                }
                if scan < rest.endIndex { scan = rest.index(after: scan) }
            }
            rest = rest[scan...]
        }
        return out + rest
    }

    /// Single-quotes for `sh`. `SSHTransport.quote` is the same rule; this is
    /// the third place in the module that needs it, and the two existing copies
    /// are private to types that have nothing to do with sessions.
    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
