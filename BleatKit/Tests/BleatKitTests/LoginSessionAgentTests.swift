import Foundation
import Testing
@testable import BleatKit

/// The launchd agent that keeps a herdr session in the desktop login session.
///
/// **Installed and run on the dev Mac, 12 Sept 2026, and proved end to end.**
/// `bleat login-session install bleat-login-test` wrote this plist, launchd
/// loaded it into `gui/501`, herdr came up, and the session's pane shell
/// reported **asid 100016** — the login session. Then, inside that pane,
/// `security show-keychain-info` answered
/// `"…/login.keychain-db" no-timeout`: the keychain is genuinely readable
/// there, which is the thing the asid was only ever a proxy for.
@Suite("Login session agent")
struct LoginSessionAgentTests {

    private func agent(
        _ name: String = "phone", herdr: String = "/opt/homebrew/bin/herdr"
    ) throws -> LoginSessionAgent {
        LoginSessionAgent(session: try #require(SessionName(name)), herdrPath: herdr)
    }

    /// Namespaced under the bundle id so the listing sweep cannot match anything
    /// but ours — the reasoning behind `bleat pair`'s `-enroll-` infix.
    @Test("the label is namespaced under the bundle id")
    func label() throws {
        #expect(try agent().label == "team.partof.bleat.herdr.phone")
        #expect(try agent().fileName == "team.partof.bleat.herdr.phone.plist")
    }

    /// `~/Library/LaunchAgents` is the only directory whose agents launchd loads
    /// into `gui/<uid>` at login, which is the whole point.
    @Test("it is installed where login loads it from")
    func location() throws {
        let url = try agent().plistURL(home: URL(fileURLWithPath: "/Users/ravil"))
        #expect(url.path == "/Users/ravil/Library/LaunchAgents/team.partof.bleat.herdr.phone.plist")
    }

    /// **The gui domain, never `user/<uid>`.** The Background domain is the one
    /// whose audit session is *not* the login session's — measured, 100041
    /// against 100016 — so loading the job there would reproduce the bug this
    /// exists to fix.
    @Test("launchctl is aimed at the login domain")
    func targets() throws {
        #expect(try agent().serviceTarget(uid: 501) == "gui/501/team.partof.bleat.herdr.phone")
        #expect(LoginSessionAgent.domainTarget(uid: 501) == "gui/501")
    }

    /// Exactly what launchd was made to run, and each `-u` is load-bearing:
    /// `HERDR_SESSION`/`HERDR_SOCKET_PATH` so a `launchctl setenv` cannot
    /// redirect which session comes up, and `CLAUDE_CODE_CHILD_SESSION` because
    /// a herdr server passes its environment to every pane it spawns and an
    /// agent with that set writes no transcript at all.
    @Test("it runs herdr through env -u, with the name as a positional")
    func programArguments() throws {
        #expect(try agent().programArguments == [
            "/usr/bin/env",
            "-u", "HERDR_SESSION",
            "-u", "HERDR_SOCKET_PATH",
            "-u", "CLAUDE_CODE_CHILD_SESSION",
            "/opt/homebrew/bin/herdr", "session", "attach", "phone",
        ])
    }

    /// **No `KeepAlive`, and it is the most important absence in the file.**
    /// `herdr session attach` with no pty exits **1 on success** — the TUI cannot
    /// draw, so it complains after the server is already up — and launchd reads
    /// that as a crash. With `KeepAlive` it would relaunch forever against a
    /// session that is running perfectly.
    @Test("it runs at load and is never kept alive")
    func noKeepAlive() throws {
        let plist = try agent().propertyList()
        #expect(plist["RunAtLoad"] as? Bool == true)
        #expect(plist["KeepAlive"] == nil)
        #expect(plist["StartInterval"] == nil)
        // No log paths, for the reason `SessionLaunch`'s log file was deleted: a
        // successful start writes only `Inappropriate ioctl for device`, and a
        // predictable path in a shared directory is a symlink to truncate.
        #expect(plist["StandardOutPath"] == nil)
        #expect(plist["StandardErrorPath"] == nil)
    }

    /// Serialised rather than templated, and this is the case that justifies it:
    /// a herdr path is arbitrary text from the filesystem, and hand-escaping it
    /// into XML is how a plist launchd silently refuses to load gets written.
    @Test("a path with XML in it survives")
    func hostilePath() throws {
        let data = try agent(herdr: #"/opt/a&b/<herdr>"#).plistData()
        let read = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as? [String: Any]
        let arguments = try #require(read?["ProgramArguments"] as? [String])
        #expect(arguments.contains(#"/opt/a&b/<herdr>"#))
    }

    /// What `plutil -p` printed for the file that was really installed.
    @Test("the plist round-trips to what launchd was given")
    func roundTrip() throws {
        let data = try agent(herdr: "/opt/homebrew/bin/herdr").plistData()
        let read = try #require(
            try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
                as? [String: Any]
        )
        #expect(read["Label"] as? String == "team.partof.bleat.herdr.phone")
        #expect(read["RunAtLoad"] as? Bool == true)
        #expect(read.keys.sorted() == ["Label", "ProgramArguments", "RunAtLoad"])
    }

    // MARK: - Listing what is installed

    /// Only ours, and only by the prefix — a `.plist` for anything else in that
    /// directory is somebody's own agent and must not be listed, let alone
    /// handed to `launchctl bootout`.
    @Test("the listing sees only its own agents")
    func listing() {
        let found = LoginSessionAgent.installedSessions(inLaunchAgents: [
            "team.partof.bleat.herdr.work.plist",
            "team.partof.bleat.herdr.phone.plist",
            "com.example.something.plist",
            "team.partof.bleat.herdr.phone.plist.bak",
            "notaplist",
            ".DS_Store",
        ])
        #expect(found == ["phone", "work"])
    }

    /// A file somebody hand-edited into a name `SessionName` refuses is listed as
    /// nothing rather than trusted: every other use of that string is a
    /// `launchctl` target or a path. The leading dash is the one that matters —
    /// `herdr session stop -- -x` cannot address such a session at all, which is
    /// why `SessionName` refuses it.
    @Test("a name that could not have been installed is not listed")
    func refusesAHandEditedName() {
        #expect(LoginSessionAgent.installedSessions(inLaunchAgents: [
            "team.partof.bleat.herdr.-x.plist",
            "team.partof.bleat.herdr...plist",
            "team.partof.bleat.herdr.has space.plist",
            "team.partof.bleat.herdr..plist",
        ]).isEmpty)
    }
}
