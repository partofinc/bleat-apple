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
/// (`-25308 & 0xFF == 36`), which means **the keychain is locked and this process
/// cannot put up a prompt to unlock it** — a state, not a place. Measured: the
/// same locked keychain reached from a session that *can* prompt answers 152
/// ("Unable to obtain authorization") instead.
///
/// So Bleat asks exactly that, over the connection it already has. One command,
/// nothing installed on the host, nothing left running, and no secret in the
/// question.
public struct LoginKeychain: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        /// `security show-keychain-info` exited 0. An agent here can sign in.
        case unlocked
        /// Exit 36, `errSecInteractionNotAllowed`: locked, and nothing in this
        /// session can ask for the passphrase. This is the state that makes an
        /// agent report `Not logged in`.
        case lockedAndCannotPrompt
        /// Any other answer, or none. Says nothing either way, and the UI shows
        /// nothing for it — the discipline `EndpointDiscovery.Report` sets.
        case unknown
    }

    public let state: State

    public init(state: State) { self.state = state }

    // MARK: - Asking

    static let statePrefix = "bleat-keychain:"
    static let unlockPrefix = "bleat-unlock:"

    /// `errSecInteractionNotAllowed`, as the `security` tool exits it: the low
    /// byte of `-25308`. This is the one value Claude Code tests for.
    public static let interactionNotAllowed = 36

    /// `errSecAuthFailed`, the low byte of `-25293`. Measured against a throwaway
    /// keychain: the wrong passphrase on stdin exits **51**, the right one 0.
    public static let authenticationFailed = 51

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

    /// Unlocks the default keychain, then **reports the state afterwards rather
    /// than the unlock's own success**.
    ///
    /// The result is checked, not assumed — the rule this package applies to
    /// every write. The unlock's exit code is reported too, because it is the
    /// only thing that separates "wrong passphrase" (51) from a keychain that is
    /// still locked for some other reason, and those need different words.
    ///
    /// **The passphrase goes on stdin, not in `-p`**, which keeps it out of
    /// `security`'s own `argv`. Measured: `printf '%s' <pw> | security
    /// unlock-keychain` unlocks, exit 0.
    ///
    /// **It is still inside the command string, and that is not hidden here.**
    /// sshd runs an exec command as `zsh -c '<command>'`, so the text is in *that*
    /// process's `argv` for as long as the command runs — visible to other
    /// processes of the same user. That is not an escalation: any process which
    /// could read it could equally read the keychain it unlocks, and could have
    /// read `authorized_keys` to begin with. What it does mean is that the string
    /// must never reach a log or an error message; callers replace a failure with
    /// their own words rather than quoting the command.
    public static func unlockCommand(passphrase: String) -> String {
        [
            "printf '%s' \(quote(passphrase)) | security unlock-keychain >/dev/null 2>&1",
            "u=$?",
            "security show-keychain-info >/dev/null 2>&1",
            "s=$?",
            "printf '\(unlockPrefix)%s\\n' \"$u\"",
            "printf '\(statePrefix)%s\\n' \"$s\"",
        ].joined(separator: "; ")
    }

    /// Single quotes, the same rule as `DirectoryCheck.quote` and
    /// `SSHTransport.quote`. A passphrase is arbitrary text and a `'` in it would
    /// otherwise end the quoting and hand the rest to the shell.
    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
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

    /// What an unlock attempt did, told apart so the message can be specific.
    public enum UnlockOutcome: Sendable, Equatable {
        /// Unlocked, and the state afterwards confirms it.
        case unlocked
        /// `errSecAuthFailed`. The passphrase is wrong, and this is the only
        /// outcome worth asking the user to try again for.
        case wrongPassphrase
        /// The unlock reported success but the keychain is still not readable, or
        /// the host answered in a way this cannot read. Deliberately one case:
        /// both mean "it did not work and I cannot say why", and inventing a
        /// distinction would be a guess.
        case failed
    }

    public static func unlockOutcome(inOutput output: String) -> UnlockOutcome {
        // The state afterwards decides, because that is the question. An unlock
        // that exits 0 over a keychain that still cannot be read is a failure
        // however cheerful its status was — the same reason `session delete`'s
        // `{"deleted":true}` is not evidence.
        if LoginKeychain(inOutput: output).state == .unlocked { return .unlocked }
        if value(of: unlockPrefix, in: output) == authenticationFailed {
            return .wrongPassphrase
        }
        return .failed
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
