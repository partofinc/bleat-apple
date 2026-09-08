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

    /// **Both halves are load-bearing and each fails differently.**
    ///
    /// Without `&` the command runs the server in the foreground and the exec
    /// channel never returns — the app hangs on a spinner for as long as the
    /// session lives. Without the redirect the backgrounded process keeps the
    /// channel's stdout open, which does the same thing for a subtler reason.
    @Test("the launch backgrounds and redirects, or the channel never closes")
    func detaches() {
        let command = start("scratch")
        #expect(command.hasSuffix("&"))
        #expect(command.contains("nohup "))
        #expect(command.contains("</dev/null"))
        #expect(command.contains("2>&1"))
    }

    /// `herdr server`, not `herdr session attach`. Attaching wants a pty and
    /// hands the session the phone's geometry, which `phone.toml` records as
    /// permanently corrupting a pane's wrapping.
    @Test("it starts the headless server, not the TUI")
    func headless() {
        let command = start("scratch")
        #expect(command.contains("'/opt/homebrew/bin/herdr' server"))
        #expect(!command.contains("attach"))
    }

    /// The same reason `SSHTransport.command` clears it: a socket path leaking
    /// in from the environment silently overrides `HERDR_SESSION`, so the
    /// command would start — or fail to start — a session other than the one
    /// the user named.
    @Test("the inherited socket path is cleared")
    func clearsSocketPath() {
        #expect(start("scratch").contains("env -u HERDR_SOCKET_PATH HERDR_SESSION='scratch'"))
    }

    /// `SessionName` has already excluded every character that means something
    /// to a shell, so this is belt and braces — but the path beside it is
    /// arbitrary, coming from the peer record.
    @Test("the herdr path is quoted")
    func quotesThePath() {
        #expect(start("scratch", herdr: "/opt/my herdr/herdr").contains("'/opt/my herdr/herdr'"))
    }

    /// A per-user directory, in double quotes because the expansion has to
    /// happen on the host rather than being passed through.
    ///
    /// **The fallback is `$HOME`, never `/tmp`.** The file name is entirely
    /// predictable, so under a world-writable directory another local account
    /// could pre-create it as a symlink and this redirect would truncate
    /// whatever it points at, as the SSH user.
    @Test("the launch log lands somewhere the phone can read it back")
    func logIsFetchable() {
        let log = SessionLaunch.logCommand(name: SessionName("scratch")!)
        #expect(start("scratch").contains(#">"${TMPDIR:-$HOME}/bleat-session-scratch.log""#))
        #expect(log.contains(#"cat "${TMPDIR:-$HOME}/bleat-session-scratch.log""#))
        #expect(!start("scratch").contains("/tmp"), "a predictable name under a shared /tmp")
    }

    /// The reason `HerdrLookup.command` ends the same way. A launch that
    /// printed nothing wrote no file, and `cat` on a missing file exits 1 — so
    /// without this the app reports "the host rejected a command (exit 1)"
    /// about a session that started perfectly well.
    @Test("a missing log is a normal answer, not a failed command")
    func absenceIsNotFailure() {
        #expect(SessionLaunch.logCommand(name: SessionName("scratch")!).hasSuffix("|| true"))
    }
}
