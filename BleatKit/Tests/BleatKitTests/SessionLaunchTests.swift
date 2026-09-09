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

    /// **The whole script, because this exact one was run against a host.**
    /// The other tests here check a property each; this pins what was actually
    /// executed over a real SSH exec channel on 9 Sept 2026 — success path,
    /// refusal path and watchdog — so a later edit that looks harmless cannot
    /// quietly diverge from the thing that was verified.
    @Test("the command is the one that was measured")
    func exactCommand() {
        #expect(start("scratch") == """
        exec 2>/dev/null
        env -u HERDR_SOCKET_PATH -u HERDR_SESSION '/opt/homebrew/bin/herdr' \
        session attach 'scratch' </dev/null 2>&1 &
        launch=$!
        ( sleep 10; kill -TERM $launch ) >/dev/null 2>&1 &
        watchdog=$!
        wait $launch
        kill $watchdog >/dev/null 2>&1
        true
        """)
    }

    /// **The launch is synchronous now, so it has to be bounded.**
    ///
    /// `nohup … &` could not hang: the shell returned whatever herdr did. A
    /// foreground command can, and a herdr that never exits holds the exec
    /// channel open forever — `NewSessionModel` never clears `isStarting`, and
    /// `NewSessionField`'s scrim is deliberately inert while a launch is in
    /// flight, so the cover cannot be dismissed and the app needs relaunching.
    ///
    /// Verified over SSH with a `sleep 600` in herdr's place and a 3s budget:
    /// the channel returned in 3.12s, the hung process was gone, and the
    /// command still exited 0.
    @Test("a launch that hangs is killed rather than held")
    func bounded() {
        let command = start("scratch")
        #expect(command.contains("kill -TERM $launch"))
        #expect(command.contains("sleep \(SessionLaunch.watchdogSeconds)"))
        // The watchdog must not be a second writer on the channel, or it holds
        // the command open for its whole budget on every run — the bug
        // `EndpointDiscovery` documents in the same shape.
        #expect(command.contains(") >/dev/null 2>&1 &"))
    }

    /// **Every outcome exits 0, and that is required rather than tidy.**
    /// The headless success path exits 1 (`Inappropriate ioctl for device`,
    /// after the server is up) and a killed launch exits on a signal.
    /// `ShellRunner.run` throws on a non-zero status, so without the trailing
    /// `true` a successful start would reach the user as "the host rejected a
    /// command (exit 1)" — the failure `HerdrLookup.command` ends in `|| true`
    /// to avoid.
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
