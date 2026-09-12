import Foundation

/// Whether an agent on this host can read the login keychain — asked the way the
/// agent itself asks.
///
/// **This replaced a wrong theory, and the wrong theory is worth recording so it
/// is not rebuilt.** The first version of this compared *audit sessions*: the
/// idea was that `session attach` over an SSH exec channel leaves herdr's server
/// in sshd's own audit session, away from the desktop login's, and that keychain
/// access follows the audit session. It was refuted by measurement on the dev
/// Mac, 12 Sept 2026 — against a session the phone really had started:
///
/// | | |
/// |---|---|
/// | `retro`'s server, restarted headless from the phone at 11:20 | **asid 100016** |
/// | `work`'s server, started at the Mac | asid 100016 |
/// | `launchctl print gui/501` — the desktop login | asid 100016 |
///
/// The phone-started one is in the *same* audit session. `/etc/pam.d/sshd` runs
/// `pam_launchd.so`, which joins an SSH login to the user's existing Aqua session
/// when there is one — which is also why `launchctl print user/501` reports
/// `gui asid = 100016`. So there was nothing to arrange, and the LaunchAgent
/// written to arrange it has been reverted.
///
/// **What actually fails is simpler, and it is read out of Claude Code itself:**
///
/// ```js
/// Rp("security", ["show-keychain-info"], …).then(e => e.exitCode === 36)
/// ```
///
/// That is the whole test behind `Not logged in · Run in another terminal:
/// security unlock-keychain`. Exit 36 is `errSecInteractionNotAllowed`
/// (`-25308 & 0xFF == 36`).
///
/// **It does not mean the keychain is locked, and reading it that way cost a
/// round trip through a feature that could not work.** Measured on the dev Mac:
/// the login keychain answered **exit 0 — unlocked** in the desktop session at
/// the same moment Bleat's check over SSH answered **36**. Same host, same
/// keychain, same minute. So 36 is a fact about *the asking connection*, which
/// can neither use the keychain nor put up a prompt for it — not about the
/// keychain's state.
///
/// Two things follow, and both were learned the hard way:
///
/// - **There is nothing to unlock.** An "unlock the keychain" button shipped
///   here for one build and was removed. It asked for a passphrase that cannot
///   help: the keychain is already unlocked for the desktop session, and over
///   SSH a passphrase was refused (`errSecAuthFailed`, 51) while an unlock
///   against an *already*-unlocked keychain returns 0 whatever passphrase it is
///   given — so the success check could not tell the difference either.
/// - **What helps is where the agent's server was started from.** A herdr server
///   started from the desktop session gives panes that can use the keychain —
///   measured, `security show-keychain-info` answered `no-timeout` inside such a
///   pane. One started over SSH does not.
///
/// So Bleat asks the question and says which sessions are usable. One command,
/// nothing installed on the host, nothing left running, and no secret in it.
public struct LoginKeychain: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        /// `security show-keychain-info` exited 0. An agent here can sign in.
        case unlocked
        /// Exit 36, `errSecInteractionNotAllowed`: this connection cannot use the
        /// keychain and cannot ask for a passphrase — whatever state the keychain
        /// is actually in. This is what makes an agent report `Not logged in`.
        ///
        /// The name keeps `locked` because 36 is what `security` returns, but the
        /// remedy is a session the Mac started, never a passphrase.
        case lockedAndCannotPrompt
        /// Any other answer, or none. Says nothing either way, and the UI shows
        /// nothing for it — the discipline `EndpointDiscovery.Report` sets.
        case unknown
    }

    public let state: State

    public init(state: State) { self.state = state }

    // MARK: - Asking

    static let statePrefix = "bleat-keychain:"

    /// `errSecInteractionNotAllowed`, as the `security` tool exits it: the low
    /// byte of `-25308`. This is the one value Claude Code tests for.
    public static let interactionNotAllowed = 36

    /// **No keychain argument, deliberately.** Claude Code passes none, so it
    /// asks about the *default* keychain, and this has to ask the same question
    /// or it can disagree with the thing it is reporting on. On this Mac the
    /// default is the login keychain — `security default-keychain` says so — but
    /// that is the host's business, not an assumption worth baking in.
    ///
    /// Exits 0 whatever the answer, because `ShellRunner.run` throws on a
    /// non-zero status: the same reason `HerdrLookup.command` ends in `|| true`.
    /// The answer is a prefixed line within stdout, never the whole of it, since
    /// a login shell sources the profile and profiles print banners.
    public static var stateCommand: String {
        "security show-keychain-info >/dev/null 2>&1; printf '\(statePrefix)%s\\n' \"$?\""
    }

    // MARK: - Reading the answer

    public init(inOutput output: String) {
        switch Self.value(of: Self.statePrefix, in: output) {
        case 0: state = .unlocked
        case Self.interactionNotAllowed: state = .lockedAndCannotPrompt
        // **Every other code is `unknown`, including the ones that clearly mean
        // trouble.** `security` has a large error space and only 36 is the state
        // an agent reports as "not logged in"; guessing at the rest would put
        // words in the host's mouth.
        default: state = .unknown
        }
    }

    /// The last line carrying `prefix`, as an exit status.
    private static func value(of prefix: String, in output: String) -> Int? {
        guard let line = output
            .split(separator: "\n", omittingEmptySubsequences: false)
            .last(where: { $0.hasPrefix(prefix) })
        else { return nil }
        return Int(line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces))
    }
}
