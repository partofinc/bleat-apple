import Foundation

/// The phone's half of pairing: arrive on a single-use key, install a durable
/// one, and destroy the key it arrived on.
///
/// Everything here is shell commands built by `AuthorizedKeys`, run through a
/// `ShellRunner`. That is what makes the sequence testable without a network
/// and without an `authorized_keys` to damage — and this sequence needs
/// testing, because its failure modes are not exceptions. They are a phone that
/// reports success and cannot connect, or a live key left on a host:
///
/// - **Delete before install** and a failure in between leaves the phone with
///   no credential at all. The enrollment key is gone, the device key never
///   landed, and the only way back is to walk to the Mac.
/// - **Trust the install** and the same thing happens one step later: the
///   append succeeded loudly and did nothing, and the enrollment key is deleted
///   anyway.
///
/// So the enrollment key is deleted **last**, and only after the host has
/// demonstrated — on a second connection, authenticated with the new key — that
/// it will let the phone back in.
public enum Enrollment {
    /// What redemption produced. Everything the phone did not already know.
    public struct Redemption: Sendable, Equatable {
        /// Absolute path to `herdr`, resolved through the host's login shell.
        public let herdrPath: String
        /// The marker on the device key's line, so it can be found and revoked
        /// later without touching keys the user installed themselves.
        public let deviceMarker: String
    }

    /// Runs the swap.
    ///
    /// - Parameters:
    ///   - deviceKey: The phone's durable key. Generated on the device, stored
    ///     in the Keychain, and never transmitted — only its public half is
    ///     written to the host, which is what any SSH key adoption does.
    ///   - enrollmentKey: The single-use key from the QR, reconstructed from
    ///     its seed. Needed here as well as for the connection, because the
    ///     line to delete is identified by the key rather than by a marker the
    ///     phone never learns.
    ///   - runner: Already connected **as the enrollment key**, and already
    ///     host-key-checked against the QR.
    ///   - openDeviceSession: Opens a second connection to the same host,
    ///     authenticated with `deviceKey`. This is the proof that the install
    ///     worked, and it is deliberately not a file check.
    ///
    ///     A line in `authorized_keys` is not the same claim as "sshd will
    ///     accept this key", and the gap between them is where a phone gets
    ///     locked out silently: `StrictModes` ignoring a file whose permissions
    ///     drifted, or an `AuthorizedKeysFile` pointing somewhere other than
    ///     `~/.ssh`. Both leave a file that reads back perfectly. Asking the
    ///     host is the only check that cannot be fooled this way — and it costs
    ///     one handshake.
    public static func redeem(
        deviceKey: SSHKeyPair,
        enrollmentKey: SSHKeyPair,
        on runner: any ShellRunner,
        openDeviceSession: @Sendable () async throws -> any ShellRunner
    ) async throws -> Redemption {
        // Resolved first, while nothing has been written. A host without herdr
        // would produce a paired peer that can list nothing, and finding that
        // out before touching authorized_keys means there is nothing to undo.
        // `bleat pair` refuses such a host already, so this is a second line of
        // defence rather than the first.
        let located = try await runner.run(shell: HerdrLookup.command)
        guard let herdrPath = HerdrLookup.path(inOutput: located) else {
            throw PairingError.herdrNotFound
        }

        let marker = AuthorizedKeys.deviceMarker()
        let deviceLine = deviceKey.authorizedKeyLine(comment: marker.value)
        let enrollmentLine = enrollmentKey.authorizedKeyLine(comment: "")

        // Re-pairing a phone that is already known would otherwise append a
        // second copy of the same key under a second marker, and the stale
        // marker would then name a line that no longer exists on its own.
        if let clear = AuthorizedKeys.removeKeyCommand(publicKeyLine: deviceLine) {
            _ = try await runner.run(shell: clear)
        }
        _ = try await runner.run(shell: AuthorizedKeys.appendCommand(line: deviceLine))

        guard try await contains(deviceLine, on: runner) else {
            // Deliberately before any deletion: the enrollment key is still
            // live and still the way back in, so the user can simply scan
            // again. Deleting it here would turn a recoverable failure into a
            // trip to the Mac.
            throw PairingError.enrollmentIncomplete(
                "the device key did not appear in \(AuthorizedKeys.path)"
            )
        }

        // The real check. Everything above proves what the file says; this
        // proves what sshd does.
        let device: any ShellRunner
        do {
            device = try await openDeviceSession()
        } catch {
            throw PairingError.enrollmentIncomplete(
                "the host would not accept the new key: \(error)"
            )
        }

        // Revoked over the *device* session, not the enrollment one. By this
        // point the enrollment key has done its job, and running its own
        // deletion through the connection that replaces it means the phone
        // never depends on it again.
        guard let remove = AuthorizedKeys.removeKeyCommand(publicKeyLine: enrollmentLine) else {
            throw PairingError.enrollmentIncomplete("the enrollment key could not be read back")
        }
        _ = try await device.run(shell: remove)

        // `bleat pair` calls the pairing done when the enrollment line is gone
        // *and* a new device marker has appeared, so a removal that exited 0
        // without removing anything would hang the tool until its window closed
        // while the phone claimed success. It would also leave a working key on
        // the host until `expiry-time` caught it, which is the whole thing this
        // design exists to avoid.
        guard try await contains(enrollmentLine, on: device) == false else {
            throw PairingError.enrollmentIncomplete(
                "the enrollment key is still in \(AuthorizedKeys.path)"
            )
        }

        return Redemption(herdrPath: herdrPath, deviceMarker: marker.value)
    }

    /// Asks the host whether a line carrying this key is present.
    ///
    /// Reads stdout rather than an exit status: the command is wrapped so that
    /// "absent" is a normal answer, not a failure, and a `ShellRunner` throws
    /// on a non-zero exit.
    static func contains(_ publicKeyLine: String, on runner: any ShellRunner) async throws -> Bool {
        guard let command = AuthorizedKeys.containsKeyCommand(publicKeyLine: publicKeyLine) else {
            throw PairingError.enrollmentIncomplete("a key could not be read back")
        }
        let answer = try await runner.run(shell: command)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Anything other than the two expected words is treated as absent
        // rather than guessed at — it means the host is not running the shell
        // we think it is, and "present" is the answer that would delete things.
        return answer == "yes"
    }
}
