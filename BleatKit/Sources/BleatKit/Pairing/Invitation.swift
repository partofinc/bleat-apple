import Foundation

/// `bleat pair`, run from a device that is already paired: a single-use
/// enrollment key installed on the host over this device's own connection, and
/// a code for the next device to scan.
///
/// **Everything the host's tool knows, the paired device knows too** — the
/// host key, the user, the addresses the host reported — so nothing here needs
/// a terminal on the host. The other device redeems the code exactly as it
/// would one from `bleat pair`: `Enrollment` cannot tell them apart, and does
/// not need to.
///
/// The three layers that keep the key from outliving the pairing are the
/// tool's, moved across:
///
/// - **Withdrawn when the screen goes**: `withdraw(on:)`, from the screen's
///   own teardown.
/// - **Withdrawn at the deadline** by the same screen, when nobody scanned.
/// - **sshd refuses it after `expiry-time`**, whatever happened to this
///   device — the app killed, the phone dead, the network gone. This is the
///   one that holds unconditionally, as it is for the tool.
///
/// **It does not sweep other enrollment keys**, where `bleat pair` does. The
/// tool runs on the host and a stale key there is its own leftover; from here,
/// another `bleat-enroll-` line may be a pairing in progress at the host's
/// keyboard or on another device, and sweeping would end it.
public struct Invitation: Sendable, Equatable {
    /// How long the code is good for — the tool's window.
    public static let window: TimeInterval = 5 * 60

    /// Extra life on the sshd-side deadline, beyond `window`, for a device
    /// that connects a second before the end and is still mid-swap. See
    /// `Pair.expiryGrace`, which is this.
    public static let expiryGrace: TimeInterval = 60

    /// What the other device scans.
    public let payload: PairingPayload
    /// The enrollment line's marker: how it is found again, and removed.
    public let marker: AuthorizedKeys.Marker
    /// When this device stops waiting and withdraws the key.
    public let deadline: Date
    /// Device keys on the host before the code was shown, so a redemption is
    /// judged on a *new* one appearing — the rule `bleat pair` follows.
    let devicesBefore: Set<String>

    /// For a caller that has these already — a preview. `open(for:on:)` is
    /// the way to get one with a key behind it.
    public init(
        payload: PairingPayload,
        marker: AuthorizedKeys.Marker,
        deadline: Date,
        devicesBefore: Set<String> = []
    ) {
        self.payload = payload
        self.marker = marker
        self.deadline = deadline
        self.devicesBefore = devicesBefore
    }

    public enum State: Sendable, Equatable {
        /// The key is still there and nobody has used it.
        case waiting
        /// The enrollment line is gone and a new device key has appeared.
        case redeemed
        /// The enrollment line is gone with no new device key: something on
        /// the host removed it — `bleat pair`'s sweep, or `bleat keys revoke`.
        case withdrawn
    }

    /// Installs the enrollment key and builds the code.
    ///
    /// - Parameters:
    ///   - peer: The host, as this device knows it. Its endpoints go into the
    ///     code as they stand — the host's own report plus anything added by
    ///     hand — and its host key is the pin the other device will check.
    ///   - runner: A shell on the host, authenticated as this device.
    public static func open(
        for peer: PairedPeer,
        on runner: any ShellRunner,
        now: Date = Date()
    ) async throws -> Invitation {
        guard !peer.endpoints.isEmpty else {
            throw PairingError.enrollmentIncomplete("this host has no address to put in the code")
        }
        let devicesBefore = try await deviceMarkers(on: runner)

        let enrollment = SSHKeyPair()
        let marker = AuthorizedKeys.enrollmentMarker()
        let deadline = now.addingTimeInterval(window)
        let line = AuthorizedKeys.enrollmentLine(
            publicKeyLine: enrollment.authorizedKeyLine(comment: ""),
            marker: marker,
            expiresAt: deadline.addingTimeInterval(expiryGrace)
        )
        _ = try await runner.run(shell: AuthorizedKeys.appendCommand(line: line))

        // An append that exited 0 and wrote nothing would show a code that
        // can never work, for five minutes. Read it back, as `Enrollment`
        // does its own key.
        guard try await contains(marker, on: runner) else {
            throw PairingError.enrollmentIncomplete(
                "the enrollment key did not appear in \(AuthorizedKeys.path)"
            )
        }

        return Invitation(
            payload: PairingPayload(
                name: peer.name,
                username: peer.username,
                endpoints: peer.endpoints,
                enrollmentSeed: enrollment.rawRepresentation,
                hostKey: peer.hostKey
            ),
            marker: marker,
            deadline: deadline,
            devicesBefore: devicesBefore
        )
    }

    /// The code, as `bleat pair` would print it.
    public func link() throws -> String { try payload.urlString() }

    /// Where things stand on the host.
    ///
    /// The enrollment line is checked **before** the device keys, and the
    /// order is what makes `withdrawn` trustworthy: the other device installs
    /// its own key before it deletes the enrollment line, so a line seen gone
    /// with no new key beside it a moment later was not taken by a redemption.
    public func state(on runner: any ShellRunner) async throws -> State {
        guard try await !Self.contains(marker, on: runner) else { return .waiting }
        let devices = try await Self.deviceMarkers(on: runner)
        return devices.subtracting(devicesBefore).isEmpty ? .withdrawn : .redeemed
    }

    /// Removes the enrollment line. Idempotent: removing a line already gone
    /// is not an error, so this is safe after a redemption and after a
    /// previous withdrawal.
    public func withdraw(on runner: any ShellRunner) async throws {
        _ = try await runner.run(shell: AuthorizedKeys.removeCommand(marker: marker))
    }

    private static func contains(
        _ marker: AuthorizedKeys.Marker,
        on runner: any ShellRunner
    ) async throws -> Bool {
        let answer = try await runner.run(shell: AuthorizedKeys.containsCommand(marker: marker))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // "Present" unless the host plainly says otherwise. Read wrongly the
        // other way, a key still live would be reported as used or withdrawn,
        // and the screen would stop watching it.
        return answer != "no"
    }

    private static func deviceMarkers(on runner: any ShellRunner) async throws -> Set<String> {
        let output = try await runner.run(shell: AuthorizedKeys.listDeviceMarkersCommand())
        return Set(
            output.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.hasPrefix(AuthorizedKeys.markerPrefix) }
        )
    }
}
