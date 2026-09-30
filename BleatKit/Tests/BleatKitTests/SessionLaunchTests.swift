import Testing
@testable import BleatKit

/// Starting a session on a host — the first thing Bleat creates there rather
/// than reads.
///
/// Everything here was read off herdr 0.9.0 on the dev Mac (8 Sept 2026) rather
/// than reasoned about, because two of the four rules are surprising and one of
/// them is a trap herdr itself does not close.
@Suite("Starting a session")
struct SessionLaunchTests {

    // MARK: - The name

    @Test("herdr's own character set is what is allowed", arguments: [
        "work", "phone", "bleat-test", "a.b", "a_b", "A1", "x",
    ])
    func acceptsWhatHerdrAccepts(_ name: String) {
        #expect(SessionName(name) != nil, "\(name) should be a usable session name")
    }

    /// The message herdr answers with is
    /// `session name may only contain ASCII letters, numbers, '.', '_' and '-'`,
    /// so a space, a slash and anything non-ASCII are all out.
    @Test("anything herdr would refuse is refused here", arguments: [
        "my session", "a/b", "a:b", "wörk", "a\tb", "a$b", "a'b", "a\"b",
    ])
    func refusesWhatHerdrRefuses(_ name: String) {
        #expect(SessionName.problem(with: name) == .illegalCharacters)
    }

    @Test("an empty name is its own answer, not an illegal character")
    func emptyIsItsOwnProblem() {
        // The field's resting state. Reported separately so a blank field is
        // not shouted at as though the user had typed something wrong.
        #expect(SessionName.problem(with: "") == .empty)
    }

    @Test(". and .. are reserved", arguments: [".", ".."])
    func reserved(_ name: String) {
        // herdr: `error: session name cannot be . or ..` — they would name its
        // own session directory's parent.
        #expect(SessionName.problem(with: name) == .reserved)
    }

    /// **The one herdr does not protect you from.**
    ///
    /// Measured: `HERDR_SESSION=-x herdr server` starts perfectly well and
    /// creates `~/.config/herdr/sessions/-x`. After that neither
    /// `herdr session stop -- -x` nor `herdr session delete -- -x` can address
    /// it — both print their usage line, because the name is parsed as a flag.
    /// The probe's server had to be killed by pid and its directory removed by
    /// hand.
    ///
    /// So this is not pedantry about a leading dash: without it the phone can
    /// leave a session running on someone's Mac that the Mac's own CLI cannot
    /// stop.
    @Test("a leading dash is refused, because herdr could not stop it again")
    func leadingDashIsRefused() {
        #expect(SessionName.problem(with: "-x") == .leadingDash)
        #expect(SessionName("-x") == nil)
        // Only *leading*: a dash elsewhere is ordinary, and `bleat-test` is a
        // real session on the dev Mac.
        #expect(SessionName("bleat-test") != nil)
    }

    // MARK: - The command

    private func start(_ name: String, herdr: String = "/opt/homebrew/bin/herdr") -> String {
        SessionLaunch.startCommand(name: SessionName(name)!, herdrPath: herdr)
    }

    /// **`session attach`, under a sized pty** — and this test replaces one
    /// that asserted the launch needed no terminal at all.
    ///
    /// herdr 0.9.0 started the server and *then* failed to draw, so a bare
    /// `attach` with no pty worked. 0.9.3 checks the terminal first and creates
    /// nothing. Measured over a real SSH exec channel, 30 Sept 2026.
    @Test("it attaches under a pty, and needs nothing to detach it")
    func attaches() {
        let command = start("scratch")
        #expect(command.contains(#"session attach "$bleat_session""#))
        #expect(!command.contains("server"))
        #expect(!command.contains("nohup"), "herdr daemonises the server itself")
        #expect(command.contains("script -q"), "0.9.3 refuses to attach without a terminal")
        #expect(
            command.contains("stty rows 40 cols 120"),
            "a pty is not enough — an unsized one is refused with 'zero-sized grid'"
        )
    }

    /// **Both `script` flavours, chosen by a probe rather than by falling
    /// through.** BSD has no `-c` and util-linux refuses the BSD form outright
    /// (`unexpected number of arguments`), so neither spelling works on both
    /// and an `||` chain could not tell "this flavour does not exist" from "the
    /// launch failed". `script -q -c true /dev/null` is the probe: exit 0 on
    /// util-linux, non-zero on BSD. Measured on both hosts.
    @Test("the script flavour is probed, not guessed")
    func bothScriptFlavours() {
        let command = start("scratch")
        #expect(command.contains("if script -q -c true /dev/null"))
        #expect(command.contains(#"script -q -c "$bleat_attach" /dev/null"#))
        #expect(command.contains(#"script -q /dev/null /bin/sh -c "$bleat_attach""#))
    }

    /// **The values never reach a nested quoting level.** They go into exported
    /// variables and the command `script` runs is a literal single-quoted
    /// string that expands them itself — because a double quote in the herdr
    /// path would otherwise escape the inner string, and that path is whatever
    /// `command -v herdr` answered on somebody else's machine.
    @Test("neither value is interpolated into the inner command")
    func noNestedQuoting() {
        let command = start("scratch", herdr: #"/opt/her"drr/herdr"#)
        #expect(command.contains(##"bleat_herdr='/opt/her"drr/herdr'"##))
        // The inner command names the variable, never the value.
        #expect(!command.contains(#"attach "/opt/her"#))
        #expect(command.contains(#""$bleat_herdr" session attach"#))
    }

    /// **The geometry is ours now, and 120×40 is herdr's own headless
    /// default** — so a session the phone starts comes up at the grid it came
    /// up at when the launch had no pty. Measured on the Linux host:
    /// `pane layout` reported `120×40`.
    @Test("the session gets herdr's headless grid, not the phone's")
    func headlessGeometry() {
        #expect(SessionLaunch.sessionColumns == 120)
        #expect(SessionLaunch.sessionRows == 40)
    }

    /// **The whole script, because this exact one was run against two hosts.**
    /// The other tests here check a property each; this pins what was actually
    /// executed over a real SSH exec channel to the Linux host and locally on
    /// the Mac on 30 Sept 2026 — success path, both `script` flavours and the
    /// poll — so a later edit that looks harmless cannot quietly diverge from
    /// the thing that was verified.
    @Test("the command is the one that was measured")
    func exactCommand() {
        #expect(start("scratch") == """
        exec 2>/dev/null
        bleat_herdr='/opt/homebrew/bin/herdr'
        bleat_session='scratch'
        export bleat_herdr bleat_session
        bleat_attach='stty rows 40 cols 120; exec env -u HERDR_SOCKET_PATH -u HERDR_SESSION "$bleat_herdr" session attach "$bleat_session"'
        bleat_ready() {
        env -u HERDR_SOCKET_PATH HERDR_SESSION="$bleat_session" "$bleat_herdr" pane list >/dev/null 2>&1
        }
        bleat_log=$(mktemp "${TMPDIR:-/tmp}/bleat-session.XXXXXX") || exit 0
        if script -q -c true /dev/null >/dev/null 2>&1; then
        script -q -c "$bleat_attach" /dev/null </dev/null >"$bleat_log" 2>&1 &
        else
        script -q /dev/null /bin/sh -c "$bleat_attach" </dev/null >"$bleat_log" 2>&1 &
        fi
        bleat_launch=$!
        bleat_tries=0
        until bleat_ready; do
        bleat_tries=$((bleat_tries + 1))
        [ "$bleat_tries" -ge 20 ] && break
        sleep 0.5
        done
        kill -TERM "$bleat_launch" >/dev/null 2>&1
        bleat_ready || cat "$bleat_log"
        rm -f "$bleat_log"
        true
        """)
    }

    /// **The client never exits on its own now, so it is always killed.**
    ///
    /// Given a working terminal `attach` *is* the TUI and stays up for as long
    /// as the channel does — so the bounded poll is not a safety net for a hang
    /// any more, it is the normal path. A herdr that never comes up holds the
    /// exec channel open otherwise, and `NewSessionModel` never clears
    /// `isStarting` while `NewSessionField`'s scrim is deliberately inert, so
    /// the cover cannot be dismissed and the app needs relaunching.
    ///
    /// **The server survives the kill** — verified on both hosts, `session
    /// list` reporting `running: true` after a `kill -TERM` of the `script`
    /// that held the client.
    @Test("the client is killed once the session answers, and the server lives")
    func killsTheClient() {
        let command = start("scratch")
        #expect(command.contains(#"kill -TERM "$bleat_launch""#))
        #expect(command.contains("until bleat_ready; do"))
        #expect(command.contains("[ \"$bleat_tries\" -ge \(SessionLaunch.pollAttempts) ] && break"))
    }

    /// **Readiness is the session's own socket answering, not a grep of
    /// `session list`.** A socket-API command against the session exits 0 only
    /// when its server is up, which is the question being asked — and it does
    /// not depend on two JSON keys staying adjacent in herdr's output.
    @Test("readiness asks the session's socket rather than parsing JSON")
    func readinessIsASocketCall() {
        let command = start("scratch")
        #expect(command.contains(#""$bleat_herdr" pane list >/dev/null 2>&1"#))
        #expect(!command.contains("grep"))
        #expect(
            command.contains(#"env -u HERDR_SOCKET_PATH HERDR_SESSION="$bleat_session""#),
            "the probe must clear the inherited socket path, which wins over the name"
        )
    }

    /// **The output is emitted only when the launch failed**, and that is what
    /// makes widening `diagnosis` safe. On success the client's output is the
    /// TUI's escape stream — several KB of nothing, and a stripped-of-ANSI
    /// haystack that could match a cause that is not one.
    @Test("nothing is reported when the session came up")
    func onlyFailureIsReported() {
        let command = start("scratch")
        #expect(command.contains(#"bleat_ready || cat "$bleat_log""#))
        #expect(command.contains(#"rm -f "$bleat_log""#))
        // `mktemp` with a template, not a predictable name: the old design's
        // `${TMPDIR:-$HOME}` log was a symlink this redirect would truncate as
        // the SSH user.
        #expect(command.contains(#"mktemp "${TMPDIR:-/tmp}/bleat-session.XXXXXX""#))
    }

    /// **Every outcome exits 0, and that is required rather than tidy.**
    /// The last thing to run is `bleat_ready || cat`, whose status is the
    /// *readiness probe's* — non-zero on exactly the launches that failed —
    /// and a `kill`ed client exits on a signal. `ShellRunner.run` throws on a
    /// non-zero status, so without the trailing `true` a failed start would
    /// reach the user as "the host rejected a command" in place of herdr's own
    /// sentence, and the cause this whole path exists to carry would be lost.
    @Test("a non-zero status is the normal answer, not a failed command")
    func successExitsNonZero() {
        #expect(start("scratch").hasSuffix("\ntrue"))
    }

    /// `SessionName` has already excluded every character that means something
    /// to a shell, so this is belt and braces — but the path beside it is
    /// arbitrary, coming from the peer record.
    @Test("the herdr path is quoted")
    func quotesThePath() {
        #expect(start("scratch", herdr: "/opt/my herdr/herdr").contains("'/opt/my herdr/herdr'"))
    }

    // MARK: - Reading a failure

    /// **The refusal the user actually met, 30 Sept 2026.** herdr 0.9.3 will
    /// not attach without a terminal, and it says so under a `herdr: ` prefix
    /// rather than `error: ` — which this function used to be the only reader
    /// of, so the sentence naming both the cause and the remedy was dropped and
    /// the user got the generic "the host did not report a session".
    ///
    /// Both hosts' exact wording, captured from real runs.
    @Test(
        "the terminal refusal is read as a cause",
        arguments: [
            "Not a tty (os error 25)",
            "Inappropriate ioctl for device (os error 25)",
            "terminal reported a zero-sized grid",
        ]
    )
    func readsTheTerminalRefusal(_ reason: String) {
        let output = "herdr: cannot attach without a usable terminal: \(reason); run inside a terminal"
        #expect(
            SessionLaunch.diagnosis(inLaunchOutput: output)
                == "cannot attach without a usable terminal: \(reason); run inside a terminal"
        )
    }

    /// **Not everything in a failed launch is herdr explaining itself.** An
    /// unresolvable `herdrPath` gets the shell's own complaint, measured on the
    /// Linux host — true, but not a cause herdr gave, so the generic message is
    /// the honest answer rather than handing the user `env:` output.
    @Test("a shell's own complaint is not passed off as herdr's")
    func shellComplaintIsNotACause() {
        let output = #"env: '/no/such/herdr': No such file or directory"#
        #expect(SessionLaunch.diagnosis(inLaunchOutput: output) == nil)
    }

    /// A bare prefix with nothing after it is not a cause either — it would
    /// reach the user as an empty "That did not happen".
    @Test("an empty cause is no cause")
    func emptyCause() {
        #expect(SessionLaunch.diagnosis(inLaunchOutput: "herdr: ") == nil)
        #expect(SessionLaunch.diagnosis(inLaunchOutput: "error: ") == nil)
    }

    /// herdr's own sentence, and nothing else.
    @Test("a refusal is reported in herdr's words")
    func readsARefusal() {
        let output = """
        error: session name may only contain ASCII letters, numbers, '.', '_' and '-'
        run 'herdr --help' for usage
        """
        #expect(
            SessionLaunch.diagnosis(inLaunchOutput: output)
                == "session name may only contain ASCII letters, numbers, '.', '_' and '-'"
        )
    }

    /// **This test asserted the opposite until 30 Sept 2026, and the reversal
    /// is the whole story of that day.**
    ///
    /// It used to say: `herdr: Inappropriate ioctl for device` is the exact
    /// output of a launch that *worked*, so it must never be read as a cause —
    /// which was true of herdr 0.9.0, where the server came up and only the TUI
    /// failed to draw. On 0.9.3 the terminal is checked first and nothing is
    /// created, so the same words are a refusal, and the old rule threw away
    /// the one sentence that explained the failure a user reported.
    ///
    /// **Two things changed together, and only the pair is safe.** `herdr: ` is
    /// accepted as a cause *because* `startCommand` now emits the client's
    /// output only when the session did not come up: there is no success path
    /// through this function any more. Widening the prefix without that would
    /// re-introduce exactly the bug the old test defended against.
    @Test("the terminal complaint is a cause now, not success noise")
    func theIoctlComplaintIsACause() {
        let output = "\u{1B}[?1006l\u{1B}[?1000lherdr: Inappropriate ioctl for device (os error 25)"
        #expect(
            SessionLaunch.diagnosis(inLaunchOutput: output)
                == "Inappropriate ioctl for device (os error 25)",
            "0.9.3 refuses before starting anything, so this is a refusal"
        )
    }

    /// **Measured, not defensive.** Captured to a file rather than a terminal,
    /// herdr still styles this one — so a prefix test on the raw bytes finds
    /// nothing and the user is told "no cause given" about a refusal herdr
    /// explained perfectly well.
    @Test("an error herdr styled is still an error")
    func stripsANSIBeforeMatching() {
        let output = "\u{1B}[1merror:\u{1B}[0m nested herdr is disabled by default."
        #expect(SessionLaunch.diagnosis(inLaunchOutput: output) == "nested herdr is disabled by default.")
    }

    /// **CSI is not the only escape herdr can emit, and the others break the
    /// match differently.** A first version stripped `ESC[…` alone, which drops
    /// the `ESC` of every other form and leaves its *payload* as text — so a
    /// title set landing on the same line as herdr's complaint (stdout and
    /// stderr are merged) hid the `error: ` prefix behind `]0;…`, and the user
    /// got the generic "did not report a session" instead of the sentence that
    /// explains it.
    @Test("an OSC title does not hide the error behind it")
    func stripsOSC() {
        let output = "\u{1B}]0;herdr — scratch\u{07}error: nested herdr is disabled by default."
        #expect(SessionLaunch.diagnosis(inLaunchOutput: output) == "nested herdr is disabled by default.")
    }

    /// The ST-terminated form of the same thing, and a two-byte designator.
    @Test("the other escape forms are stripped too", arguments: [
        "\u{1B}]0;title\u{1B}\\error: boom",
        "\u{1B}(Berror: boom",
        "\u{1B}=error: boom",
    ])
    func stripsOtherForms(_ output: String) {
        #expect(SessionLaunch.diagnosis(inLaunchOutput: output) == "boom")
    }

    /// **Narrow on purpose.** This reads a diagnostic, so a sequence the
    /// stripper does not know must survive into the message rather than being
    /// eaten — losing half of herdr's sentence is worse than leaving a stray
    /// byte in it.
    @Test("an unrecognised escape does not eat the message")
    func leavesUnknownSequencesAlone() {
        // Only the ESC byte goes; everything after it survives. Losing half of
        // herdr's sentence to an over-eager stripper is worse than leaving a
        // stray character in it, so an unknown form is skipped, not consumed.
        #expect(SessionLaunch.diagnosis(inLaunchOutput: "error: it \u{1B}qbroke") == "it qbroke")
    }

    @Test("nothing worth quoting is nil, never a guess")
    func silenceIsNil() {
        #expect(SessionLaunch.diagnosis(inLaunchOutput: "") == nil)
        #expect(SessionLaunch.diagnosis(inLaunchOutput: "starting server\nlistening") == nil)
    }
}
