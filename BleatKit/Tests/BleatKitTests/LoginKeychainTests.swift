import Foundation
import Testing
@testable import BleatKit

/// Whether an agent can read the login keychain, asked the way the agent asks.
///
/// **Both commands were run verbatim on the dev Mac, 12 Sept 2026**, under `sh`
/// and `zsh` (sshd runs zsh on a modern macOS): the state command against the
/// real default keychain, and the unlock against a throwaway keychain with both
/// the right passphrase and a wrong one. The exit codes below are those
/// measurements, not lore.
@Suite("Login keychain")
struct LoginKeychainTests {

    /// Claude Code runs `security show-keychain-info` with **no keychain
    /// argument** and tests for exit 36, so this asks the same question of the
    /// same keychain. Asking about `login.keychain-db` explicitly would be a
    /// different question, and could disagree with the thing being reported on.
    @Test("the state command is what was run, and names no keychain")
    func stateCommand() {
        #expect(LoginKeychain.stateCommand
            == #"security show-keychain-info >/dev/null 2>&1; printf 'bleat-keychain:%s\n' "$?""#)
        #expect(!LoginKeychain.stateCommand.contains("login.keychain"))
    }

    /// 36 is `errSecInteractionNotAllowed`, the low byte of `-25308` — locked,
    /// **and** nothing here can ask for the passphrase. Measured contrast: the
    /// same locked keychain from a session that *can* prompt answers 152, and a
    /// still-locked keychain after a failed unlock in such a session answered 24.
    /// Neither is the state an agent reports as "not logged in".
    @Test("only 36 is the state that stops an agent signing in")
    func readsTheState() {
        #expect(LoginKeychain(inOutput: "bleat-keychain:0\n").state == .unlocked)
        #expect(LoginKeychain(inOutput: "bleat-keychain:36\n").state == .lockedAndCannotPrompt)
        for other in [1, 24, 51, 152] {
            #expect(LoginKeychain(inOutput: "bleat-keychain:\(other)\n").state == .unknown)
        }
    }

    /// **Nothing learned must never read as a verdict**, the discipline
    /// `EndpointDiscovery.Report` sets. A host with no `security` at all — every
    /// Linux one — answers with a code this does not recognise, and the UI shows
    /// nothing for `.unknown`.
    @Test("no answer is unknown, never a verdict")
    func unknownWithoutAnAnswer() {
        #expect(LoginKeychain(inOutput: "").state == .unknown)
        #expect(LoginKeychain(inOutput: "bleat-keychain:\n").state == .unknown)
        #expect(LoginKeychain(inOutput: "bleat-keychain:not-a-number\n").state == .unknown)
    }

    /// sshd runs this through a login shell, `.zshenv` is sourced for every
    /// non-interactive zsh, and profiles print banners — the mistake
    /// `PeerConnector`'s `printf ok` probe made.
    @Test("a chatty login shell does not defeat it")
    func survivesABanner() {
        #expect(LoginKeychain(inOutput: """
            Welcome back!
            bleat-keychain:36
            nvm: version 20 in use
            """).state == .lockedAndCannotPrompt)
    }

    // MARK: - Unlocking

    /// **The passphrase goes on stdin, never in `-p`**, which keeps it out of
    /// `security`'s own `argv`. Measured: piping it unlocks, exit 0.
    @Test("the passphrase is piped, not passed as a flag")
    func unlockUsesStdin() {
        let command = LoginKeychain.unlockCommand(passphrase: "sw0rdfish")
        #expect(command.hasPrefix("printf '%s' 'sw0rdfish' | security unlock-keychain"))
        #expect(!command.contains("-p "))
        // No keychain argument, for the same reason the state command has none.
        #expect(!command.contains("login.keychain"))
    }

    /// A passphrase is arbitrary text, and a `'` in it would otherwise close the
    /// quoting and hand the rest of it to the shell — the same rule
    /// `DirectoryCheck.quote` follows for a path.
    @Test("a quote in the passphrase cannot escape the quoting")
    func quotesArePhrase() {
        let command = LoginKeychain.unlockCommand(passphrase: "it's a 'test'")
        #expect(command.contains(#"'it'\''s a '\''test'\'''"#))
    }

    /// **The state afterwards decides, not the unlock's own status.** An unlock
    /// that exits 0 over a keychain that still cannot be read is a failure
    /// however cheerful its status was — the same reason `session delete`
    /// answering `{"deleted":true}` over a session that never existed is not
    /// evidence.
    @Test("the unlock is judged by the state it left behind")
    func unlockIsChecked() {
        #expect(LoginKeychain.unlockOutcome(inOutput: """
            bleat-unlock:0
            bleat-keychain:0
            """) == .unlocked)
        // Exited 0 and the keychain is still unreadable: not success.
        #expect(LoginKeychain.unlockOutcome(inOutput: """
            bleat-unlock:0
            bleat-keychain:36
            """) == .failed)
    }

    /// 51 is `errSecAuthFailed`, the low byte of `-25293`. Measured against a
    /// throwaway keychain: the wrong passphrase on stdin exits **51** while the
    /// right one exits 0. It is the only outcome worth offering a retry for.
    @Test("a wrong passphrase is told apart from everything else")
    func wrongPassphrase() {
        #expect(LoginKeychain.unlockOutcome(inOutput: """
            bleat-unlock:51
            bleat-keychain:24
            """) == .wrongPassphrase)
        // Some other failure. One case on purpose: both mean "it did not work
        // and I cannot say why", and splitting them would be a guess.
        #expect(LoginKeychain.unlockOutcome(inOutput: """
            bleat-unlock:1
            bleat-keychain:36
            """) == .failed)
        #expect(LoginKeychain.unlockOutcome(inOutput: "") == .failed)
    }

    /// The exact bytes the two measurements produced, so the parser and the thing
    /// that was measured cannot drift.
    @Test("the measured replies parse the way they were observed")
    func measuredReplies() {
        #expect(LoginKeychain.unlockOutcome(inOutput: "bleat-unlock:51\nbleat-keychain:24\n")
            == .wrongPassphrase)
        #expect(LoginKeychain.unlockOutcome(inOutput: "bleat-unlock:0\nbleat-keychain:0\n")
            == .unlocked)
        #expect(LoginKeychain(inOutput: "bleat-keychain:0\n").state == .unlocked)
    }
}
