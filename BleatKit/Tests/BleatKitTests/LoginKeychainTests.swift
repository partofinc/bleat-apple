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

    /// **Exit 36 is not "the keychain is locked", and the first version of this
    /// read it that way.** Measured: the login keychain answered exit 0 in the
    /// desktop session at the same moment the check over SSH answered 36 — same
    /// host, same keychain. So the state says something about the asking
    /// connection, and the remedy is a session the Mac started rather than a
    /// passphrase. An unlock button shipped for one build on the wrong reading
    /// and was removed; there is deliberately no unlock surface here now.
    @Test("there is no unlock surface, on purpose")
    func noUnlockSurface() {
        // A passphrase cannot help, so none is asked for. If this ever needs
        // reinstating, read the type's doc comment first.
        #expect(LoginKeychain.stateCommand.contains("show-keychain-info"))
        #expect(!LoginKeychain.stateCommand.contains("unlock"))
    }
}
