import Foundation

/// Whether a session's panes can reach the Mac's login keychain.
///
/// **The problem this reports, measured on the dev Mac 12 Sept 2026.** macOS
/// scopes keychain access to the *audit session* (`asid`), a process inherits
/// its asid from its parent at spawn, and nothing can move a running process
/// into another one. So:
///
/// - a session started at the Mac has its server in the Aqua login session.
///   Measured: `herdr server` pid 42463, its pane's shell 42603 and the
///   `claude` running in that pane 46175 were **all asid 100016**, which is
///   what `launchctl print gui/501` reports as the login session.
/// - a session the phone started ran `session attach` over an SSH exec
///   channel, so its server — and therefore every pane and every agent it will
///   ever spawn — is in sshd's audit session instead. Claude Code there reports
///   `Not logged in · Run in another terminal: security unlock-keychain`.
///
/// **Attaching a TUI at the Mac does not repair it, and that is the part worth
/// knowing.** The client is a new process in the login session; the panes are
/// still children of the server in the other one. There is nothing to unlock
/// and no lock to flip — `security unlock-keychain` acts on the session it is
/// run in, so at the Mac it helps a shell nobody is using. Reported from a
/// device as "even if I continue such a session from the mac it stays locked".
///
/// So this is a *diagnosis*, offered before the user spends half a minute
/// starting an agent that cannot sign in. It changes nothing on the host.
///
/// **Only ever reports what it actually learned.** Both asids have to come
/// back, or the answer is `.unknown` and the UI says nothing at all — the same
/// discipline as `EndpointDiscovery.Report`, where a probe that gave no
/// confident answer must not be read as a claim. Telling someone their agents
/// cannot sign in because a command did not run is worse than staying quiet.
public struct SecuritySession: Sendable, Equatable {
    /// The audit session of the session's panes, read from a pane's shell.
    ///
    /// A pane's shell is a direct child of the herdr server, so its asid *is*
    /// the server's — which is what every future pane and agent will inherit.
    /// `pane process-info` reports it as `shell_pid`, and it is always present
    /// even when no program is in the foreground.
    public let paneAsid: Int?

    /// The audit session of the Mac's GUI login, which is the one whose
    /// keychain is unlocked.
    public let loginAsid: Int?

    /// Whether `launchctl print gui/<uid>` answered, as opposed to the answer
    /// arriving only through the Background domain's `gui asid` field.
    ///
    /// Recorded because it is the first evidence about whether a session like
    /// this could be *fixed* by starting the server in the GUI domain: a host
    /// that will not even let this session read that domain will certainly not
    /// let it start a job there. **It is evidence, not proof** — reading a
    /// domain and creating a job in it are different permissions, and the two
    /// do come apart: measured from the Aqua session, `launchctl print user/501`
    /// and `launchctl kickstart user/501/<missing label>` both resolved the
    /// Background domain while `launchctl bootstrap user/501 <plist>` was
    /// refused outright with `5: Input/output error`.
    public let readLoginDomainDirectly: Bool

    public init(paneAsid: Int?, loginAsid: Int?, readLoginDomainDirectly: Bool) {
        self.paneAsid = paneAsid
        self.loginAsid = loginAsid
        self.readLoginDomainDirectly = readLoginDomainDirectly
    }

    public enum Reach: Sendable, Equatable {
        /// The panes share the GUI login's audit session, so the keychain is
        /// reachable and an agent can sign in.
        case sharedWithLogin
        /// The panes are in a different audit session. Agents that need an
        /// account cannot read its credentials, and nothing done at the Mac
        /// changes that for this server.
        case detached
        /// The host could not be asked. Says nothing either way.
        case unknown
    }

    public var reach: Reach {
        guard let paneAsid, let loginAsid else { return .unknown }
        return paneAsid == loginAsid ? .sharedWithLogin : .detached
    }

    // MARK: - The probe

    static let panePrefix = "bleat-asid-pane:"
    static let loginPrefix = "bleat-asid-login:"
    static let loginViaBackgroundPrefix = "bleat-asid-login-via-background:"

    /// `launchctl print pid/<pid>` reports a **dead pid as the caller's own
    /// security context**, and that trap is why this is not a one-line grep.
    ///
    /// Measured: `launchctl print pid/999999` exits cleanly and prints
    /// `asid = 100016` — the asid of whoever asked — distinguished from a live
    /// process only by `uniqueid = 0`. Unguarded, a pane whose shell had
    /// already gone would be reported as sharing whatever session the probe
    /// itself ran in: from a phone that is the SSH session, so two detached
    /// sessions would compare equal and the pane would be called fine. The
    /// guard is `uniqueid > 0`, taken in the same pass.
    static let paneAsidProgram =
        #"/^[[:space:]]*uniqueid = /{u=$2} /^[[:space:]]*asid = /{a=$2} END{if (u+0 > 0 && a != "") print a}"#

    /// The login session's own asid. In `launchctl print gui/<uid>` the first
    /// `asid` line is the domain's security context, and it equals the
    /// `handle` — both were 100016 on the dev Mac.
    static let loginAsidProgram = #"/^[[:space:]]*asid = /{print $2; exit}"#

    /// `launchctl print user/<uid>` — the *Background* domain — names the GUI
    /// session in a field of its own: `gui asid = 100016`, beside its own
    /// `asid = 100041`. That makes it a second source for the same number, and
    /// a likelier one to answer from a session that is not the GUI's.
    ///
    /// The anchor matters: `/^[[:space:]]*asid = /` deliberately does **not**
    /// match `gui asid = `, so the two programs cannot read each other's field.
    static let loginAsidViaBackgroundProgram = #"/^[[:space:]]*gui asid = /{print $2; exit}"#

    /// - Parameter paneShellPid: `shell_pid` from `pane process-info`.
    ///   Interpolated into a command the host will run, so it is checked rather
    ///   than trusted, exactly as `PtyResize.command` checks its own.
    /// - Returns: nil when the pid is not a plausible process id.
    ///
    /// One command, three prefixed lines, and it exits 0 whatever happens —
    /// `ShellRunner.run` throws on a non-zero status, so a host with no
    /// `launchctl` at all (every Linux one) would otherwise reach the user as
    /// "the host rejected a command". The same reason `HerdrLookup.command`
    /// ends in `|| true`. An absent answer is an empty value after the prefix,
    /// which reads back as nil.
    ///
    /// **Prefixed lines, never the whole of stdout**, for the reason
    /// `DirectoryCheck` reads its answer that way: sshd runs this through a
    /// login shell, `.zshenv` is sourced for every non-interactive zsh, and
    /// profiles print banners.
    public static func command(paneShellPid pid: Int) -> String? {
        guard pid > 0, pid < 4_194_304 else { return nil }
        return [
            "u=$(/usr/bin/id -u)",
            line(panePrefix, from: "/bin/launchctl print pid/\(pid)", program: paneAsidProgram),
            line(loginPrefix, from: "/bin/launchctl print gui/$u", program: loginAsidProgram),
            line(
                loginViaBackgroundPrefix,
                from: "/bin/launchctl print user/$u",
                program: loginAsidViaBackgroundProgram
            ),
            "true",
        ].joined(separator: "; ")
    }

    private static func line(_ prefix: String, from command: String, program: String) -> String {
        "printf '\(prefix)%s\\n' \"$(\(command) 2>/dev/null | /usr/bin/awk -F'= ' '\(program)')\""
    }

    /// Reads the three lines back out of the host's stdout.
    ///
    /// The direct `gui/<uid>` reading wins when both answered; they are the
    /// same number from two places, and preferring the direct one is what makes
    /// `readLoginDomainDirectly` mean something.
    public init(inOutput output: String) {
        let pane = Self.value(of: Self.panePrefix, in: output)
        let direct = Self.value(of: Self.loginPrefix, in: output)
        let viaBackground = Self.value(of: Self.loginViaBackgroundPrefix, in: output)
        self.init(
            paneAsid: pane,
            loginAsid: direct ?? viaBackground,
            readLoginDomainDirectly: direct != nil
        )
    }

    /// The last line carrying `prefix`, as a positive integer.
    ///
    /// An asid is a small positive number; anything else is a host that
    /// answered with something other than one, and guessing at it would be the
    /// `{"deleted":true}` mistake this package refuses everywhere else.
    private static func value(of prefix: String, in output: String) -> Int? {
        guard let line = output
            .split(separator: "\n", omittingEmptySubsequences: false)
            .last(where: { $0.hasPrefix(prefix) })
        else { return nil }
        let value = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        guard let asid = Int(value), asid > 0 else { return nil }
        return asid
    }
}
