import Foundation

/// A launchd agent that keeps a herdr session running in the Mac's **desktop
/// login session**, so agents in it can sign in.
///
/// This is the answer to `SecuritySession`. A session the phone starts runs
/// `session attach` over an SSH exec channel, which leaves its server — and
/// every pane and agent it will ever spawn — in sshd's audit session, where the
/// login keychain is unreadable. Nothing can move a running process between
/// audit sessions, so the fix has to be applied *when the server starts*.
///
/// A job in the `gui/<uid>` domain starts in the Aqua session. Measured on the
/// dev Mac 12 Sept 2026: `launchctl bootstrap gui/501 <plist>` exited 0 and the
/// job reported **asid 100016**, which is what `launchctl print gui/501` gives
/// as the login session. So the server this installs is in the same audit
/// session as the desktop login, and the phone never starts it — it attaches.
///
/// **Why the phone does not do this itself.** Whether an SSH-descended process
/// may *create* a job in that domain is unverified, and the other direction says
/// not to assume: from the Aqua session, `launchctl print user/501` and
/// `launchctl kickstart user/501/<missing label>` both resolved the Background
/// domain while `launchctl bootstrap user/501 <plist>` was refused outright with
/// `5: Input/output error`. Reading a domain and creating a job in it are
/// different permissions. So this is installed at the Mac, by `bleat`, like
/// `bleat keys` and for a related reason: it is a standing change to what runs
/// at login.
///
/// **The phone cannot stop it either, and that falls out of a rule that already
/// exists.** Stop is offered only for sessions in `startedSessions` — the ones
/// this install is why are running — and a session launchd brought up is not one
/// of them. So the swipe is simply absent, which is the right answer: a session
/// the phone stopped would come back on the next login in Aqua, but a phone that
/// *restarted* it in between would have put it back in the SSH session and
/// silently undone this.
public struct LoginSessionAgent: Sendable, Equatable {
    /// Validated, never sanitised — the `Marker(text:)` rule. The name reaches
    /// a launchd label, a filename under `~/Library/LaunchAgents` and a
    /// `launchctl` domain target, and `SessionName` already refuses everything
    /// that would be dangerous in any of them: it allows only ASCII letters,
    /// digits, `.`, `_` and `-`, and refuses `.`, `..` and a leading dash.
    public let session: SessionName

    /// Absolute path to `herdr`, resolved before anything is written.
    public let herdrPath: String

    public init(session: SessionName, herdrPath: String) {
        self.session = session
        self.herdrPath = herdrPath
    }

    /// Namespaced under the app's bundle id so the sweep in `installed(in:)`
    /// cannot match anything but ours — the same reasoning as the `-enroll-`
    /// infix that keeps `bleat pair`'s sweep off a paired device's key.
    public static let labelPrefix = "team.partof.bleat.herdr."

    public var label: String { Self.labelPrefix + session.text }
    public var fileName: String { label + ".plist" }

    /// `~/Library/LaunchAgents`, which is the only directory whose agents are
    /// loaded into `gui/<uid>` at login.
    public static func launchAgentsDirectory(home: URL) -> URL {
        home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    }

    public func plistURL(home: URL) -> URL {
        Self.launchAgentsDirectory(home: home).appendingPathComponent(fileName)
    }

    /// `launchctl`'s service target. The domain is `gui/<uid>`, never `user/<uid>`
    /// — the Background domain is the one whose asid is *not* the login session's.
    public func serviceTarget(uid: Int) -> String { "gui/\(uid)/\(label)" }

    public static func domainTarget(uid: Int) -> String { "gui/\(uid)" }

    /// What launchd runs.
    ///
    /// **`env -u` rather than the bare binary**, for the two reasons
    /// `SessionLaunch` gives and one more:
    ///
    /// - `HERDR_SESSION` and `HERDR_SOCKET_PATH` are unset because the name is
    ///   a positional argument and an inherited value must not be able to
    ///   redirect which session comes up. launchd does not source a login
    ///   profile, so the realistic source is `launchctl setenv`, which is
    ///   exactly the case worth being defended against — it is invisible from
    ///   here and applies to every job in the domain.
    /// - `CLAUDE_CODE_CHILD_SESSION` is unset because a herdr server passes its
    ///   environment to every pane it spawns, and an agent started with that
    ///   set writes **no transcript** — the pane says "Transcript saving is
    ///   off" and chat mode then has nothing to read. CLAUDE.md records this as
    ///   something that has to be stripped *at the server*, and this is the
    ///   server.
    public var programArguments: [String] {
        [
            "/usr/bin/env",
            "-u", "HERDR_SESSION",
            "-u", "HERDR_SOCKET_PATH",
            "-u", "CLAUDE_CODE_CHILD_SESSION",
            herdrPath, "session", "attach", session.text,
        ]
    }

    /// **No `KeepAlive`, and that is not an omission.** `herdr session attach`
    /// with no pty **exits 1 on success** — measured, and recorded under
    /// *Starting a session*: the TUI cannot draw without a pty, so it complains
    /// and exits 1 *after* the server is up and daemonised. launchd reads that
    /// as a failure, so `KeepAlive` — or `KeepAlive { SuccessfulExit: false }` —
    /// would restart it forever, several times a second, against a session that
    /// is already running perfectly.
    ///
    /// `RunAtLoad` alone is what is wanted: the session comes up at login and
    /// at install, and the server then persists on its own. That also closes
    /// the gap CLAUDE.md names — a Mac that rebooted with nothing up — without
    /// a poll.
    ///
    /// No `StandardOutPath`/`StandardErrorPath`, for the reason
    /// `SessionLaunch`'s log file was deleted: the only thing a successful start
    /// writes is `Inappropriate ioctl for device`, and a predictable path under
    /// a world-writable directory is a symlink waiting to be truncated.
    public func propertyList() -> [String: Any] {
        [
            "Label": label,
            "ProgramArguments": programArguments,
            "RunAtLoad": true,
        ]
    }

    /// The plist as bytes.
    ///
    /// Serialised rather than templated: the herdr path is arbitrary text from
    /// the filesystem and could hold `&` or `<`, and a hand-escaped XML
    /// template is how that becomes a plist launchd silently refuses to load.
    public func plistData() throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: propertyList(), format: .xml, options: 0
        )
    }

    /// The agents this tool has installed, by session name.
    ///
    /// Matches on the label prefix, so it cannot see anything but ours.
    public static func installedSessions(inLaunchAgents names: [String]) -> [String] {
        names.compactMap { name in
            guard name.hasPrefix(labelPrefix), name.hasSuffix(".plist") else { return nil }
            let session = name.dropFirst(labelPrefix.count).dropLast(".plist".count)
            // A file somebody hand-edited into an invalid name is listed as
            // nothing rather than trusted: every other use of this string is a
            // `launchctl` target.
            return SessionName(String(session))?.text
        }
        .sorted()
    }
}
