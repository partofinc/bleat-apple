import Foundation
import Testing
@testable import BleatKit

/// Whether a session's panes can reach the login keychain.
///
/// The probe was **run verbatim on the dev Mac**, under both `sh` and `zsh`
/// (sshd runs zsh on a modern macOS), against a live pane shell, a dead pid and
/// a host with no `launchctl` at all. `commandIsWhatWasRunOnTheHost` pins the
/// string so the test and the thing that was verified cannot drift, which is
/// the rule `SessionLaunch` set for the session-start script.
@Suite("Security session")
struct SecuritySessionTests {

    /// Exactly the string that was run. Every `2>/dev/null`, the `-F'= '` and
    /// the trailing `true` is load-bearing; see the doc comments on each.
    @Test("the command is the one that was run on the host")
    func commandIsWhatWasRunOnTheHost() throws {
        let command = try #require(SecuritySession.command(paneShellPid: 42603))
        #expect(command == #"u=$(/usr/bin/id -u); printf 'bleat-asid-pane:%s\n' "$(/bin/launchctl print pid/42603 2>/dev/null | /usr/bin/awk -F'= ' '/^[[:space:]]*uniqueid = /{u=$2} /^[[:space:]]*asid = /{a=$2} END{if (u+0 > 0 && a != "") print a}')"; printf 'bleat-asid-login:%s\n' "$(/bin/launchctl print gui/$u 2>/dev/null | /usr/bin/awk -F'= ' '/^[[:space:]]*asid = /{print $2; exit}')"; printf 'bleat-asid-login-via-background:%s\n' "$(/bin/launchctl print user/$u 2>/dev/null | /usr/bin/awk -F'= ' '/^[[:space:]]*gui asid = /{print $2; exit}')"; true"#)
    }

    /// The pid arrives as JSON from the host and is interpolated into a command
    /// the host will run, so it is checked rather than trusted — the same
    /// posture as `PtyResize.command`.
    @Test("an implausible pid is refused", arguments: [0, -1, 4_194_304, Int.max])
    func refusesAnImplausiblePid(_ pid: Int) {
        #expect(SecuritySession.command(paneShellPid: pid) == nil)
    }

    // MARK: - Reading the answer

    /// What the dev Mac really said about a pane of the `work` session, which
    /// was started at the Mac.
    @Test("a pane in the login session can reach the keychain")
    func sharesTheLoginSession() {
        let session = SecuritySession(inOutput: """
            bleat-asid-pane:100016
            bleat-asid-login:100016
            bleat-asid-login-via-background:100016
            """)
        #expect(session.reach == .sharedWithLogin)
        #expect(session.paneAsid == 100016)
        #expect(session.readLoginDomainDirectly)
    }

    /// The phone-started case: sshd's audit session is not the login one, so an
    /// agent there cannot read the credentials and nothing at the Mac fixes it.
    @Test("a pane in another audit session is detached")
    func detachedFromTheLoginSession() {
        let session = SecuritySession(inOutput: """
            bleat-asid-pane:100041
            bleat-asid-login:100016
            bleat-asid-login-via-background:100016
            """)
        #expect(session.reach == .detached)
    }

    /// **Nothing learned must never read as a claim**, the discipline
    /// `EndpointDiscovery.Report` sets: saying "your agents cannot sign in"
    /// because a command did not run is worse than saying nothing.
    @Test("a missing answer is unknown, never a verdict")
    func unknownWithoutBothHalves() {
        #expect(SecuritySession(inOutput: "bleat-asid-pane:100016\n").reach == .unknown)
        #expect(SecuritySession(inOutput: "bleat-asid-login:100016\n").reach == .unknown)
        #expect(SecuritySession(inOutput: "").reach == .unknown)
    }

    /// Measured: with `/bin/launchctl` absent — every Linux host — all three
    /// values come back empty and the command still exits 0.
    @Test("a host with no launchctl is unknown, not detached")
    func hostWithoutLaunchctl() {
        let session = SecuritySession(inOutput: """
            bleat-asid-pane:
            bleat-asid-login:
            bleat-asid-login-via-background:
            """)
        #expect(session.reach == .unknown)
        #expect(!session.readLoginDomainDirectly)
    }

    /// The Background domain names the GUI session in a field of its own, which
    /// makes it a second source for the same number — and a likelier one to
    /// answer from a session that is not the GUI's.
    @Test("the Background domain is a fallback source for the login session")
    func fallsBackToTheBackgroundDomain() {
        let session = SecuritySession(inOutput: """
            bleat-asid-pane:100041
            bleat-asid-login:
            bleat-asid-login-via-background:100016
            """)
        #expect(session.loginAsid == 100016)
        #expect(session.reach == .detached)
        // The datum that says whether starting a job in that domain is even
        // worth attempting.
        #expect(!session.readLoginDomainDirectly)
    }

    @Test("the direct reading wins when both answered")
    func prefersTheDirectReading() {
        let session = SecuritySession(inOutput: """
            bleat-asid-pane:100016
            bleat-asid-login:100016
            bleat-asid-login-via-background:100016
            """)
        #expect(session.readLoginDomainDirectly)
    }

    /// sshd runs this through a login shell, `.zshenv` is sourced for every
    /// non-interactive zsh, and profiles print banners — the mistake
    /// `PeerConnector`'s `printf ok` probe made.
    @Test("a chatty login shell does not defeat it")
    func survivesALoginShellBanner() {
        let session = SecuritySession(inOutput: """
            Welcome back!
            You have mail.
            bleat-asid-pane:100041
            bleat-asid-login:100016
            bleat-asid-login-via-background:100016
            nvm: version 20 in use
            """)
        #expect(session.reach == .detached)
    }

    @Test("an answer that is not a number is no answer")
    func refusesANonNumericAnswer() {
        let session = SecuritySession(inOutput: """
            bleat-asid-pane:not-a-number
            bleat-asid-login:0
            bleat-asid-login-via-background:
            """)
        #expect(session.paneAsid == nil)
        #expect(session.loginAsid == nil)
        #expect(session.reach == .unknown)
    }

    // MARK: - The fields the awk programs depend on

    /// `launchctl print pid/<live>` — the field spellings the probe matches. If
    /// a future macOS renames one, this fails and names the awk that has to
    /// change, which nothing else would catch: the awk runs on the host and no
    /// test can execute it.
    @Test("a live pid names its own audit session")
    func livePidFixture() throws {
        let text = try Fixture.text("launchctl-print-pid.txt")
        #expect(text.contains("\tuniqueid = 42603\n"))
        #expect(text.contains("\t\tasid = 100016\n"))
    }

    /// **The trap the `uniqueid` guard exists for.** `launchctl print
    /// pid/999999` exits cleanly and reports `asid = 100016` — the asid of
    /// whoever asked — so a pane whose shell had already gone would be reported
    /// as sharing whatever session the probe itself ran in. Only `uniqueid = 0`
    /// tells them apart.
    @Test("a dead pid answers with the caller's session")
    func deadPidFixtureIsTheTrap() throws {
        let text = try Fixture.text("launchctl-print-pid-dead.txt")
        #expect(text.contains("\tuniqueid = 0\n"))
        #expect(text.contains("\t\tasid = 100016\n"))
    }

    /// The GUI domain's own security context, which is the login session.
    @Test("the gui domain reports the login session")
    func guiDomainFixture() throws {
        let text = try Fixture.text("launchctl-print-gui-head.txt")
        #expect(text.contains("\thandle = 100016\n"))
        #expect(text.contains("\t\tasid = 100016\n"))
        #expect(text.contains("\tsession = Aqua\n"))
    }

    /// The Background domain carries **both** numbers, which is why the two awk
    /// programs are anchored differently: `/^[[:space:]]*asid = /` must not
    /// match `gui asid = `, or the fallback would report the Background session
    /// as the login one and every detached session would look fine.
    @Test("the Background domain carries both numbers, and they must not be confused")
    func backgroundDomainFixture() throws {
        let text = try Fixture.text("launchctl-print-user-head.txt")
        #expect(text.contains("\tgui asid = 100016\n"))
        #expect(text.contains("\t\tasid = 100041\n"))
        #expect(text.contains("\tsession = Background\n"))

        // The line the login program would take from this output is the
        // Background one — which is exactly why it is never run against it.
        let firstPlainAsid = text
            .split(separator: "\n")
            .first { $0.drop(while: \.isWhitespace).hasPrefix("asid = ") }
        #expect(firstPlainAsid?.contains("100041") == true)
    }
}
