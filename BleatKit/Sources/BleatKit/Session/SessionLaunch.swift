import Foundation

/// Starting a named Herdr session on a host.
///
/// **Not `session attach`, and that was the question worth answering.** The
/// obvious reading of herdr's CLI is that `herdr session attach <name>` is how
/// a session comes into being, and that a client needs a pty to run it. Both
/// halves are wrong for this app:
///
/// - `attach` is the TUI. It wants a pty, and the pty it gets becomes the
///   session's geometry — so a phone attaching would resize every pane in the
///   session to the phone's idea of a terminal. `phone.toml` records what that
///   costs: herdr does not restore the geometry when the client detaches, and a
///   pane's buffer keeps the wrapping it already had, so the screen is corrupt
///   from then on. The user's own `phone-session.sh` says it in one line —
///   *"do not attach; talk to it instead."*
/// - `herdr server` needs no pty at all. It is the headless launcher, and
///   `HERDR_SESSION=<name> herdr server` brings that session up with its
///   geometry taken from `headless_cols`/`headless_rows` — which is the
///   phone-shaped answer CLAUDE.md already argues for.
///
/// Verified against herdr 0.9.0 on the dev Mac, 8 Sept 2026: launched over a
/// plain (non-pty) shell with stdio redirected, the server reparented to pid 1,
/// survived its shell exiting, and appeared in `session list` as running within
/// 0.05s. There is still **no `session create`** on 0.9.0 — `herdr session`
/// offers only `list`, `attach`, `stop`, `delete` — so this is the whole of it.
///
/// Two consequences the caller has to live with, both structural:
///
/// - **The exit status means nothing.** `nohup … &` returns the *shell's*
///   status, which is 0 whether or not herdr started. A launch that fails —
///   the commonest case being a session of that name already running, which
///   exits 1 with `error: herdr server is already running` — is indistinguishable
///   at the channel. So starting a session is a write that must be *checked*,
///   by reading `session list` back, exactly as a revocation is.
/// - **The redirect is not tidiness.** A background process still holding the
///   channel's stdout keeps the channel open, so the command would never
///   return. `logCommand` fetches what was redirected, which is the only way
///   herdr's own complaint reaches the phone.
public enum SessionLaunch {

    /// Starts `name` on the host, detached, and returns immediately.
    ///
    /// - Parameter herdrPath: Absolute, from the `PairedPeer`. A non-login
    ///   shell usually has no `herdr` on `PATH`.
    public static func startCommand(name: SessionName, herdrPath: String) -> String {
        // `-u HERDR_SOCKET_PATH` for the reason `SSHTransport.command` clears
        // it: a socket path leaking in from the environment pins the command to
        // a different session and silently overrides `HERDR_SESSION` — here
        // that would start, or fail to start, something other than what the
        // user typed.
        "nohup env -u HERDR_SOCKET_PATH HERDR_SESSION=\(quote(name.text)) "
            + "\(quote(herdrPath)) server </dev/null >\(logRedirect(for: name)) 2>&1 &"
    }

    /// What the launch printed, or nothing.
    ///
    /// `|| true` for the reason `HerdrLookup.command` has one: a missing file
    /// is a normal answer here — it means the launch produced no output worth
    /// keeping — and without it the caller is told "the host rejected a command
    /// (exit 1)" about a session that started perfectly well.
    public static func logCommand(name: SessionName) -> String {
        "cat \(logRedirect(for: name)) 2>/dev/null || true"
    }

    /// Where the launch's own output goes.
    ///
    /// A **shell word**, not a path: `${TMPDIR:-/tmp}` is expanded on the host,
    /// so it is emitted in double quotes rather than single ones. On macOS
    /// `TMPDIR` is a per-user directory, which a predictable name under a
    /// world-writable `/tmp` is not — the fallback is there for a host without
    /// one, not as the intent.
    ///
    /// **Truncating (`>`), never appending.** The log is read back to explain a
    /// launch that produced no session, so it has to be about *this* attempt:
    /// appending would leave the previous run's success banner on top and the
    /// phone would report a start that never happened. Verified both ways
    /// against the live host — a second launch of a running session replaced
    /// the banner with `error: herdr server is already running`.
    ///
    /// Interpolating the name unquoted inside double quotes is safe only
    /// because `SessionName` has already excluded every character that means
    /// something there: no `$`, no backtick, no backslash, no `"`. That is the
    /// type's job, and this is the line that depends on it.
    private static func logRedirect(for name: SessionName) -> String {
        "\"${TMPDIR:-/tmp}/bleat-session-\(name.text).log\""
    }

    /// Single-quotes for `sh`. `SSHTransport.quote` is the same rule; this is
    /// the third place in the module that needs it, and the two existing copies
    /// are private to types that have nothing to do with sessions.
    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
