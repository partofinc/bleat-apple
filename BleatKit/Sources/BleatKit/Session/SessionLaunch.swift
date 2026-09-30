import Foundation

/// Starting a named Herdr session on a host.
///
/// **`herdr session attach <name>`, under a sized pty.** There is still no
/// `session create` on 0.9.3 — `herdr session` offers only `list`, `attach`,
/// `stop`, `delete` — so `attach` is the only thing that brings a session into
/// being, and since 0.9.x it will not do it without a terminal.
///
/// ### What changed under this file, and how it was found
///
/// Reported from a device, 30 Sept 2026: starting a session on the Linux host
/// was "rejected". It was not a Linux problem and not a host problem — **it was
/// broken on every host**, and had been since herdr updated. Both machines run
/// **0.9.3**; every measurement this file used to rest on was taken against
/// **0.9.0**.
///
/// On 0.9.0, `attach` with no pty **started the server and then failed to
/// draw**: exit 1, `Inappropriate ioctl for device`, server up and reparented
/// to pid 1. That ordering was the whole premise of the old command, which
/// therefore swallowed the status and read the session back.
///
/// On 0.9.3 the terminal is checked **first** and nothing is created. Measured
/// over a real SSH exec channel to the Linux host, and locally with a stripped
/// environment on the Mac:
///
/// | host | given | herdr says |
/// |---|---|---|
/// | Linux | no pty | `cannot attach without a usable terminal: Not a tty (os error 25); run inside a terminal` |
/// | macOS | no pty | `cannot attach without a usable terminal: Inappropriate ioctl for device (os error 25); run inside a terminal` |
/// | Linux | a pty with no size (`script` alone) | `cannot attach without a usable terminal: terminal reported a zero-sized grid; run inside a terminal` |
///
/// The third row is the one that would have cost another round: a pty is not
/// enough, it has to have been **sized**. So the launch runs under `script`
/// with an explicit `stty`.
///
/// ### Consequences the caller lives with
///
/// - **The client no longer exits, so it is killed.** Given a working terminal
///   `attach` is the TUI and stays up for as long as the channel does. The
///   script polls until the session's own socket answers, then kills the
///   client; herdr daemonises the server, so it **survives** — verified on both
///   hosts, `session list` reporting `running: true` after a `kill -TERM`. The
///   bounded poll replaces the old `( sleep N; kill )` watchdog, which existed
///   for the same reason and can now be the same loop.
/// - **The geometry is ours to choose, and 120×40 is not arbitrary.** With a
///   pty, the pty's size *is* the session's — the hazard the 0.9.0-era design
///   feared, now unavoidable. `sessionColumns`/`sessionRows` are herdr's own
///   headless defaults, so a session started from the phone comes up at exactly
///   the grid it used to. Measured on the Linux host: `pane layout` reported
///   `120×40`.
/// - **The output is emitted only when the launch failed**, which is what makes
///   `diagnosis` safe to widen — see there. On success the client's output is
///   the TUI's escape stream, which is worth nothing and would be several KB on
///   every start.
/// - **The launch is still checked, not trusted.** `SessionStarter` reads
///   `session list` back, as it always did. The script's own readiness poll is
///   inside the thing being checked and is no substitute for it.
public enum SessionLaunch {

    /// The pty's grid, and therefore the session's.
    ///
    /// **herdr's own headless defaults**, chosen so that a session started from
    /// the phone comes up at the same size it did when the launch had no pty at
    /// all. The phone's own screen would be the wrong answer: the grid belongs
    /// to the session and every pane in it shares it, so a phone-shaped session
    /// is a decision for the host's `config.toml` rather than for whichever
    /// device happened to start it.
    public static let sessionColumns = 120
    public static let sessionRows = 40

    /// Wall clock, not a number of tries, and that distinction is the whole
    /// point.
    ///
    /// **A count of iterations is not a bound.** A first version polled twenty
    /// times and called that the limit — but each poll runs a `herdr` command
    /// with no timeout of its own, and a server whose socket exists without
    /// answering blocks one iteration indefinitely. That is the wedged-daemon
    /// case `EndpointDiscovery.tailscaleStatusCommand` already carries a
    /// watchdog for, and the `( sleep N; kill )` this replaced *was* a hard
    /// wall-clock bound. Losing it put back the failure it existed for: the
    /// exec channel held open forever, `NewSessionModel` never clearing
    /// `isStarting`, `NewSessionField`'s scrim inert, and the app needing a
    /// relaunch.
    public static let readyDeadlineSeconds = 15

    /// How long any one readiness probe may take before it is killed, so the
    /// deadline above can actually be met.
    public static let probeTimeoutSeconds = 3

    /// Starts `name` on the host and returns once its socket answers — or as
    /// soon as the client dies, which is what a refusal looks like now.
    ///
    /// - Parameter herdrPath: Absolute, from the `PairedPeer`. A non-login
    ///   shell usually has no `herdr` on `PATH`.
    public static func startCommand(name: SessionName, herdrPath: String) -> String {
        // **Nothing is interpolated into a nested quoting level.** The two
        // values go into exported variables and the command `script` runs is a
        // literal single-quoted string that expands them itself. Built the
        // obvious way instead, a double quote anywhere in the path escapes the
        // inner string — and the path is whatever `command -v herdr` answered on
        // someone else's machine.
        //
        // `-u HERDR_SOCKET_PATH` for the reason `SSHTransport.command` clears
        // it, and it is cleared in the *probe* as well as the launch: a socket
        // path leaking in from the environment wins over the name. That is not
        // hypothetical — it caught the probe that measured this change, where
        // `HERDR_SESSION=<probe> herdr pane list` answered about `work`.
        //
        // **The client is killed on two conditions, not one.** Waiting only on
        // the deadline meant every refusal cost the whole budget: measured at
        // 10.16s for a herdr that refused instantly, with the new-session cover
        // locked for all of it because its scrim is inert while a launch is in
        // flight. `kill -0` ends the loop the moment the client is gone, which
        // is also what makes emitting the log honest — see below.
        """
        exec 2>/dev/null
        bleat_herdr=\(quote(herdrPath))
        bleat_session=\(quote(name.text))
        export bleat_herdr bleat_session
        bleat_attach='stty rows \(sessionRows) cols \(sessionColumns); exec env -u HERDR_SOCKET_PATH -u HERDR_SESSION "$bleat_herdr" session attach "$bleat_session"'
        bleat_ready() {
        env -u HERDR_SOCKET_PATH HERDR_SESSION="$bleat_session" "$bleat_herdr" pane list >/dev/null 2>&1 &
        bleat_probe=$!
        ( sleep \(probeTimeoutSeconds); kill -TERM $bleat_probe ) >/dev/null 2>&1 &
        bleat_probe_guard=$!
        wait $bleat_probe
        bleat_answered=$?
        kill $bleat_probe_guard >/dev/null 2>&1
        return $bleat_answered
        }
        bleat_log=$(mktemp "${TMPDIR:-/tmp}/bleat-session.XXXXXX") || bleat_log=/dev/null
        if script -q -c true /dev/null >/dev/null 2>&1; then
        script -q -c "$bleat_attach" /dev/null </dev/null >"$bleat_log" 2>&1 &
        else
        script -q /dev/null /bin/sh -c "$bleat_attach" </dev/null >"$bleat_log" 2>&1 &
        fi
        bleat_launch=$!
        bleat_deadline=$(($(date +%s) + \(readyDeadlineSeconds)))
        bleat_died=
        until bleat_ready; do
        kill -0 "$bleat_launch" 2>/dev/null || { bleat_died=1; break; }
        [ "$(date +%s)" -ge "$bleat_deadline" ] && break
        sleep 0.5
        done
        kill -TERM "$bleat_launch" >/dev/null 2>&1
        [ -n "$bleat_died" ] && cat "$bleat_log"
        [ "$bleat_log" = /dev/null ] || rm -f "$bleat_log"
        true
        """
    }
    /// herdr's own account of why a launch produced no session, or nil.
    ///
    /// **Two prefixes, and the second one is the bug that was reported.** herdr
    /// writes its refusals both ways — `error: nested herdr is disabled by
    /// default` and `herdr: cannot attach without a usable terminal: …` — and
    /// this used to accept only the first. So the one failure a user actually
    /// met arrived as the generic "the host did not report a session", throwing
    /// away a sentence that named the cause *and* the remedy.
    ///
    /// **Accepting `herdr: ` is safe only because of when this is called.** The
    /// rule here used to be "only `error: `, because a launch that *worked*
    /// printed `herdr: Inappropriate ioctl for device`" — and that was right at
    /// the time: the output was the launch's, merged, on every run. It is not
    /// any more. `startCommand` emits the client's output **only when the
    /// session did not come up**, so everything reaching this function is from
    /// a failure by construction, and a `herdr: ` line in it is a cause rather
    /// than success noise.
    ///
    /// Anything else is still nil rather than guessed — a shell's own
    /// complaint about an unresolvable `herdrPath` reads as
    /// `env: '/no/such/herdr': No such file or directory`, which is true but is
    /// not herdr explaining itself, and the generic message is the honest
    /// answer there. Measured on the Linux host.
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
            .map { applyBackspaces(stripANSI(String($0))) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .compactMap { line in
                causePrefixes.lazy
                    .filter { line.hasPrefix($0) }
                    .map { String(line.dropFirst($0.count)) }
                    .first { !$0.isEmpty }
            }
            .first
    }

    /// The two ways herdr introduces a refusal of its own. Order matters only
    /// in that a line can match one of them.
    private static let causePrefixes = ["error: ", "herdr: "]

    /// Applies backspaces, because the pty echoes its own EOF over the top of
    /// herdr's first line.
    ///
    /// **This is the bug that shipped inside the fix for the bug.** `script`
    /// writes the EOF character to the pty master — stdin is `</dev/null` — and
    /// the line discipline echoes it as the two *printable* characters `^D`
    /// followed by two backspaces to rub them out. So a refusal arrives as
    /// `5E 44 08 08 68 65 72 64 72 3A …`: `^D`, erased, then `herdr: cannot
    /// attach without a usable terminal: …`. Captured from a real run on the
    /// Mac.
    ///
    /// `trimmingCharacters(in: .whitespacesAndNewlines)` does not touch either
    /// piece, so `hasPrefix("herdr: ")` was false and `diagnosis` returned nil
    /// — handing the user the generic "the host did not report a session" that
    /// widening the prefix was meant to replace.
    ///
    /// **Stripping control characters would not have fixed it**, which is the
    /// trap here: `^D` is `^` and `D`, two ordinary printable bytes, so
    /// removing the `\u{08}`s leaves them behind and the prefix still does not
    /// match. What removes them is doing what the backspaces ask — which is
    /// also the general answer, since anything else a pty echoes over its own
    /// output arrives the same way.
    ///
    /// Searching *within* the line for the prefix, the way
    /// `HerdrLookup.path(inOutput:)` does for profile banners, was the
    /// alternative. It is not taken: this scans whatever the TUI painted before
    /// it died, and a substring match over that is far likelier to find a
    /// "cause" that is a fragment of somebody's prompt.
    private static func applyBackspaces(_ text: String) -> String {
        guard text.contains(backspace) else { return text }
        var out = ""
        for character in text {
            if character == backspace {
                // A backspace at the start of a line has nothing to erase; a
                // terminal would simply not move, so neither does this.
                if !out.isEmpty { out.removeLast() }
            } else {
                out.append(character)
            }
        }
        return out
    }

    private static let backspace: Character = "\u{08}"

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
