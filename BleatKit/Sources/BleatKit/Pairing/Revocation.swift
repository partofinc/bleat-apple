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
    ///   - runner: Connected to the host **and authenticated with
    ///     `deviceKey`**, which is not a convenience here — it is what makes
    ///     the check below meaningful. It is also fine that the credential is
    ///     the thing being deleted: sshd authorises at the handshake and does
    ///     not re-read `authorized_keys` for a live session, so the reads still
    ///     run afterwards.
    ///
    /// - Throws: `PairingError.revocationIncomplete` when the key was not in
    ///   the file to begin with, or is still there afterwards. Never reported
    ///   as success: a phone that says "unpaired" over a key that still works
    ///   is the exact lie this whole feature exists to stop.
    public static func revokeDeviceKey(
        _ deviceKey: SSHKeyPair,
        on runner: any ShellRunner
    ) async throws {
        let line = deviceKey.authorizedKeyLine(comment: "")

        // **Absent before the removal is a failure, not a no-op.** The
        // handshake that opened this connection proves sshd accepts this key,
        // so sshd is reading it from *somewhere*; if it is not here, the file
        // being edited is not the file being read and nothing done to it can
        // revoke anything. That is not hypothetical — it is the live failure
        // CLAUDE.md records from pairing, an `AuthorizedKeysFile` pointing away
        // from the session's own `~`, and it is why `Enrollment` proves its
        // install with a second handshake instead of a file check.
        //
        // Without this the app removed nothing, reported success, deleted the
        // `PairedPeer` — and left the phone a full shell on that Mac with no
        // record naming the line.
        guard try await Enrollment.contains(line, on: runner) else {
            throw PairingError.revocationIncomplete(
                "the host accepts this key but it is not in \(AuthorizedKeys.path), "
                + "so sshd is reading a different AuthorizedKeysFile"
            )
        }

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
