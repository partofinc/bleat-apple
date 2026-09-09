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
///   script ends in a bare `true` — without it `ShellRunner.run` throws on
///   every successful start. **Never show that text to the user.**
/// - **A refusal exits 2** and says why, on stderr, synchronously — a real
///   improvement on the old command, whose status was the shell's and therefore
///   meant nothing at all. `diagnosis(inLaunchOutput:)` reads it.
/// - **The launch is still checked, not trusted.** Exit 1 cannot tell "server
///   up, TUI could not draw" from "TUI could not draw for another reason", so
///   `SessionStarter` still reads `session list` back. That rule was never
///   about `herdr server` specifically.
public enum SessionLaunch {

    /// How long the host is given to run the launch before it is killed.
    ///
    /// Measured at 0.14s over a real exec channel, so this is two orders of
    /// magnitude of headroom rather than a guess at a duration.
    public static let watchdogSeconds = 10

    /// Starts `name` on the host and returns as soon as the server is up.
    ///
    /// **Bounded, because this command is now synchronous.** The old
    /// `nohup … &` could not hang — the shell returned whatever herdr did — and
    /// giving that up for a foreground command means a herdr that does not exit
    /// holds the exec channel open forever. `NewSessionModel` never clears
    /// `isStarting` then, and `NewSessionField`'s scrim is deliberately inert
    /// while a launch is in flight, so the cover cannot be dismissed and the
    /// app needs relaunching. That is a worse failure than any this rewrite
    /// removed, and it is not hypothetical: it is exactly what the *deleted*
    /// redirect was guarding against one layer down, and a herdr that tolerated
    /// a non-tty rather than erroring on the ioctl would produce it.
    ///
    /// The `( sleep N; kill )` shape is `EndpointDiscovery.tailscaleStatusCommand`'s,
    /// for the same reason and with the same two details: the watchdog's own
    /// output goes to `/dev/null` so it is not a second writer holding the
    /// channel open, and the shell's `Terminated: 15` notice is suppressed.
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
        // The trailing `true` is `HerdrLookup.command`'s `|| true` in another
        // shape, and it is required rather than tidy: `wait` yields the
        // launch's own status, the ordinary success is exit 1, and a watchdog
        // kill exits on a signal. `ShellRunner.run` throws on any of them.
        """
        exec 2>/dev/null
        env -u HERDR_SOCKET_PATH -u HERDR_SESSION \(quote(herdrPath)) \
        session attach \(quote(name.text)) </dev/null 2>&1 &
        launch=$!
        ( sleep \(watchdogSeconds); kill -TERM $launch ) >/dev/null 2>&1 &
        watchdog=$!
        wait $launch
        kill $watchdog >/dev/null 2>&1
        true
        """
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

    /// Drops the escape sequences a terminal program writes, so the text
    /// underneath can be matched.
    ///
    /// **CSI is not the only form, and the others are not theoretical here.**
    /// A first version handled `ESC[…` alone, which drops the `ESC` of every
    /// other kind and leaves its *payload* as visible text. herdr's TUI writes
    /// control sequences to a non-tty — the whole reason this function exists —
    /// and stdout and stderr are merged into one stream by the launch, so a
    /// title set (`ESC]0;herdr — scratch BEL`) landing on the same line as
    /// herdr's complaint would leave `]0;herdr — scratch\u{07}error: …`. The
    /// `error: ` prefix test then fails and the user gets the generic "the host
    /// did not report a session" in place of herdr's own sentence — the exact
    /// failure this whole path exists to prevent.
    ///
    /// Three forms, and everything else is left alone. Deliberately narrow:
    /// this reads a diagnostic, so an unrecognised sequence must survive into
    /// the message rather than being silently eaten.
    private static func stripANSI(_ text: String) -> String {
        var out = ""
        var rest = Substring(text)
        while let esc = rest.firstIndex(of: escape) {
            out += rest[rest.startIndex..<esc]
            var scan = rest.index(after: esc)
            guard scan < rest.endIndex else { rest = rest[scan...]; break }
            switch rest[scan] {
            case "[":
                // CSI: parameter and intermediate bytes, then a final in @-~.
                scan = rest.index(after: scan)
                while scan < rest.endIndex, !("\u{40}"..."\u{7E}").contains(rest[scan]) {
                    scan = rest.index(after: scan)
                }
                if scan < rest.endIndex { scan = rest.index(after: scan) }
            case "]":
                // OSC: runs to BEL or to ST (`ESC \`). An unterminated one runs
                // to end of line, which is the right reading — the rest of that
                // line is the sequence's payload, not a message.
                scan = rest.index(after: scan)
                while scan < rest.endIndex {
                    if rest[scan] == "\u{07}" { scan = rest.index(after: scan); break }
                    if rest[scan] == escape,
                       rest.index(after: scan) < rest.endIndex,
                       rest[rest.index(after: scan)] == "\\" {
                        scan = rest.index(scan, offsetBy: 2)
                        break
                    }
                    scan = rest.index(after: scan)
                }
            case "(", ")", "*", "+", "%", "#":
                // Two-byte designators (`ESC(B` and friends): the escape, the
                // intermediate, and one more byte.
                scan = rest.index(after: scan)
                if scan < rest.endIndex { scan = rest.index(after: scan) }
            case "=", ">", "7", "8", "c", "D", "E", "H", "M", "Z":
                // Two-byte forms with no argument.
                scan = rest.index(after: scan)
            default:
                break
            }
            rest = rest[scan...]
        }
        return out + rest
    }

    private static let escape: Character = "\u{1B}"

    /// Single-quotes for `sh`. `SSHTransport.quote` is the same rule; this is
    /// the third place in the module that needs it, and the two existing copies
    /// are private to types that have nothing to do with sessions.
    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
