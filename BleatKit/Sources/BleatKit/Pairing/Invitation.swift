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
    private(set) var devicesBefore: Set<String>

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

    /// Installs the enrollment key and builds the code: `prepare`, then
    /// `install`.
    public static func open(
        for peer: PairedPeer,
        on runner: any ShellRunner,
        now: Date = Date()
    ) async throws -> Invitation {
        try await prepare(for: peer, now: now).install(on: runner)
    }

    /// Mints the key and the code, touching nothing on the host.
    ///
    /// Apart from `install` so a caller holds the marker **before** anything
    /// is written: cancelled part way through installing, it can still
    /// withdraw a line it never saw confirmed.
    ///
    /// - Parameter peer: The host, as this device knows it. Its endpoints go
    ///   into the code as they stand — the host's own report plus anything
    ///   added by hand — and its host key is the pin the other device will
    ///   check.
    public static func prepare(for peer: PairedPeer, now: Date = Date()) throws -> Invitation {
        guard !peer.endpoints.isEmpty else {
            throw PairingError.enrollmentIncomplete("this host has no address to put in the code")
        }
        return Invitation(
            payload: PairingPayload(
                name: peer.name,
                username: peer.username,
                endpoints: peer.endpoints,
                enrollmentSeed: SSHKeyPair().rawRepresentation,
                hostKey: peer.hostKey
            ),
            marker: AuthorizedKeys.enrollmentMarker(),
            deadline: now.addingTimeInterval(window)
        )
    }

    /// Writes the key to the host and confirms it is there.
    ///
    /// - Parameter runner: A shell on the host, authenticated as this device.
    /// - Returns: This invitation, knowing which device keys were already
    ///   on the host.
    public func install(on runner: any ShellRunner) async throws -> Invitation {
        let before = try await Self.snapshot(on: runner)
        let line = AuthorizedKeys.enrollmentLine(
            publicKeyLine: try payload.enrollmentKey().authorizedKeyLine(comment: ""),
            marker: marker,
            expiresAt: deadline.addingTimeInterval(Self.expiryGrace)
        )
        _ = try await runner.run(shell: AuthorizedKeys.appendCommand(line: line))

        // An append that exited 0 and wrote nothing would show a code that
        // can never work, for five minutes. Read it back, as `Enrollment`
        // does its own key.
        guard try await Self.snapshot(on: runner).markers.contains(marker.value) else {
            throw PairingError.enrollmentIncomplete(
                "the enrollment key did not appear in \(AuthorizedKeys.path)"
            )
        }
        var installed = self
        installed.devicesBefore = before.devices
        return installed
    }

    /// The code, as `bleat pair` would print it.
    public func link() throws -> String { try payload.urlString() }

    /// Where things stand on the host.
    ///
    /// **One locked read of the file**, and both are load-bearing. Every
    /// write-back to `authorized_keys` empties the file before it fills it,
    /// so an unlocked read can land in that instant and see nothing — which
    /// here would end the watch with the key still live, reported as used or
    /// removed. One read, rather than one for the line and one for the device
    /// keys, so the two answers come from the same file.
    public func state(on runner: any ShellRunner) async throws -> State {
        let now = try await Self.snapshot(on: runner)
        if now.markers.contains(marker.value) { return .waiting }
        return now.devices.subtracting(devicesBefore).isEmpty ? .withdrawn : .redeemed
    }

    /// Removes the enrollment line. Idempotent: removing a line already gone
    /// is not an error, so this is safe after a redemption and after a
    /// previous withdrawal.
    public func withdraw(on runner: any ShellRunner) async throws {
        _ = try await runner.run(shell: AuthorizedKeys.removeCommand(marker: marker))
    }

    /// The marker on every Bleat line, read under the lock the writers take.
    private static func snapshot(
        on runner: any ShellRunner
    ) async throws -> (markers: Set<String>, devices: Set<String>) {
        let output = try await runner.run(shell: AuthorizedKeys.listCommand())
        // The comment is the line's last field; the listing matched it.
        let markers = Set(
            output.split(whereSeparator: \.isNewline)
                .compactMap { $0.split(whereSeparator: \.isWhitespace).last.map(String.init) }
        )
        let devicePrefix = "\(AuthorizedKeys.markerPrefix)-device-"
        return (markers, markers.filter { $0.hasPrefix(devicePrefix) })
    }
}
