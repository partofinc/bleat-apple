import Foundation

/// The phone's half of *un*-pairing: take this device's key back off the host.
///
/// `Enrollment` is the swap that installs it; this is the only thing that
/// removes it from the phone's side. Without it, unpairing drops the phone's
/// own record and leaves a `bleat-device-…` line in the host's
/// `authorized_keys` granting a full shell — permanently, and to a phone that
/// may by then be in someone else's hands.
public enum Revocation {
    /// Removes every line carrying this device's key, and proves it is gone.
    ///
    /// - Parameters:
    ///   - deviceKey: The phone's durable key. Matched on the key itself rather
    ///     than on `PairedPeer.deviceMarker`, and deliberately: the phone always
    ///     holds the key, while a marker can be missing from a record made
    ///     before it was stored, or stale if the file was edited. The marker is
    ///     for *telling the user* which line to remove when this cannot.
    ///   - runner: Connected to the host. Very probably authenticated **with
    ///     the key being removed**, which is fine — sshd authorises at the
    ///     handshake and does not re-read `authorized_keys` for a live session,
    ///     so the verification read below still runs on the connection whose
    ///     credential has just been deleted.
    ///
    /// - Throws: `PairingError.revocationIncomplete` when the key is still
    ///   there afterwards. Never reported as success: a phone that says
    ///   "unpaired" over a key that still works is the exact lie this whole
    ///   feature exists to stop.
    public static func revokeDeviceKey(
        _ deviceKey: SSHKeyPair,
        on runner: any ShellRunner
    ) async throws {
        let line = deviceKey.authorizedKeyLine(comment: "")
        guard let remove = AuthorizedKeys.removeKeyCommand(publicKeyLine: line) else {
            throw PairingError.revocationIncomplete("this device's key could not be read back")
        }
        _ = try await runner.run(shell: remove)

        // Asked rather than assumed. `removeCommand` ends in `|| true` because
        // `grep -v` exits 1 when it emits nothing, so a removal that matched
        // nothing — a mangled line, an `authorized_keys` that turned read-only
        // between the two — exits 0 exactly like one that worked.
        guard try await Enrollment.contains(line, on: runner) == false else {
            throw PairingError.revocationIncomplete(
                "the key is still in \(AuthorizedKeys.path) after removing it"
            )
        }
    }
}
