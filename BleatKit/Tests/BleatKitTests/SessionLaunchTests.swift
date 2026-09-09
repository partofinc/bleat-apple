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

    /// **`session attach`, not `herdr server`**, and this test replaces one
    /// that asserted the opposite.
    ///
    /// The old command was `nohup env … herdr server </dev/null >LOG 2>&1 &`,
    /// built on the belief that `attach` needs a pty and would hand the session
    /// the phone's geometry. Measured over a real SSH exec channel on 9 Sept
    /// 2026: with no pty there is no geometry to hand over, the pane came up at
    /// the headless 120×40, herdr daemonised the server itself (fds all
    /// `/dev/null`, reparented to pid 1) and the channel returned in 0.14s.
    /// Every one of `nohup`, `&` and the redirect was defending against
    /// something herdr had already done.
    @Test("it attaches, and needs nothing to detach it")
    func attaches() {
        let command = start("scratch")
        #expect(command.contains("'/opt/homebrew/bin/herdr' session attach 'scratch'"))
        #expect(!command.contains("server"))
        #expect(!command.contains("nohup"), "herdr daemonises the server itself")
        #expect(!command.hasSuffix("&"), "backgrounding a command that already returns")
    }

    /// **The whole string, because this exact one was run against a host.**
    /// The other tests here check a property each; this pins the command that
    /// was actually executed over a real SSH exec channel on 9 Sept 2026 —
    /// success path and refusal path both — so a later edit that looks harmless
    /// cannot quietly diverge from the thing that was verified.
    @Test("the command is the one that was measured")
    func exactCommand() {
        #expect(
            start("scratch")
                == "env -u HERDR_SOCKET_PATH -u HERDR_SESSION '/opt/homebrew/bin/herdr' "
                + "session attach 'scratch' </dev/null 2>&1 || true"
        )
    }

    /// The TUI reads stdin, and its refusal goes to stderr — which is now the
    /// only account of a failure there will be, since there is no log file.
    @Test("stdin is closed and stderr is kept")
    func stdio() {
        let command = start("scratch")
        #expect(command.contains("</dev/null"))
        #expect(command.contains("2>&1"))
    }

    /// **Exit 1 is the success path**, which is the sharpest edge here.
    /// Without a pty the TUI cannot draw, so it prints `Inappropriate ioctl for
    /// device` and exits 1 *after* the server is up. `ShellRunner.run` throws
    /// on a non-zero status, so without this every successful start would
    /// arrive at the user as "the host rejected a command (exit 1)" — the same
    /// failure `HerdrLookup.command` ends in `|| true` to avoid.
    @Test("a non-zero status is the normal answer, not a failed command")
    func successExitsNonZero() {
        #expect(start("scratch").hasSuffix("|| true"))
    }

    /// `HERDR_SOCKET_PATH` for the reason `SSHTransport.command` clears it.
    /// `HERDR_SESSION` is the new one and matters more: the name is a
    /// positional argument now, so an inherited variable would decide which
    /// session starts.
    @Test("both inherited session variables are cleared")
    func clearsInheritedSelection() {
        #expect(start("scratch").contains("env -u HERDR_SOCKET_PATH -u HERDR_SESSION"))
    }

    /// `SessionName` has already excluded every character that means something
    /// to a shell, so this is belt and braces — but the path beside it is
    /// arbitrary, coming from the peer record.
    @Test("the herdr path is quoted")
    func quotesThePath() {
        #expect(start("scratch", herdr: "/opt/my herdr/herdr").contains("'/opt/my herdr/herdr'"))
    }

    // MARK: - Reading a failure

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

    /// **The success path must not be read as a cause.** This is the exact
    /// output of a launch that worked, captured over SSH — escape sequences,
    /// `herdr: ` prefix and all. Offering it under "that did not happen" would
    /// be herdr's own success shown as the reason for a failure, which is the
    /// mistake `SessionStarter` used to make with the startup banner.
    @Test("the headless success noise is not a failure")
    func ignoresTheIoctlComplaint() {
        let output = "\u{1B}[?1006l\u{1B}[?1000lherdr: Inappropriate ioctl for device (os error 25)"
        #expect(SessionLaunch.diagnosis(inLaunchOutput: output) == nil)
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

    @Test("nothing worth quoting is nil, never a guess")
    func silenceIsNil() {
        #expect(SessionLaunch.diagnosis(inLaunchOutput: "") == nil)
        #expect(SessionLaunch.diagnosis(inLaunchOutput: "starting server\nlistening") == nil)
    }
}
