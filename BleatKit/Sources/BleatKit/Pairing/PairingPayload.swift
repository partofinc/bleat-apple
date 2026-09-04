import Crypto
import Foundation

/// What the QR carries: enough for the phone to reach the host once, as
/// somebody the host already trusts, and to know it reached the right host.
///
/// **The seed here is a single-use enrollment key, never the device's durable
/// key.** A QR on screen is captured by anyone in the room, by any screen
/// share and by any recording; in a terminal it lands in scrollback, which
/// iTerm2 persists to disk by default. A long-lived SSH private key put there
/// outlives the pairing it was meant to serve, and an SSH private key is
/// arbitrary command execution on the host. So the host mints a throwaway key,
/// the phone uses it exactly once to install a key it generated itself, and the
/// throwaway is deleted. See CLAUDE.md, "Pairing and peer identity".
///
/// `hostKey` is the other half of the point: the phone pins the host key from
/// the QR rather than trusting whatever answers first, which is strictly
/// stronger than the trust-on-first-use `KnownHostsStore` does.
/// `herdrPath` is deliberately **not** a field here. The tool refuses to pair a
/// host without herdr, so it exists; the phone resolves the path itself with
/// `command -v herdr` through a login shell on first connect. Baking it in cost
/// 24 bytes of QR and would go stale the moment herdr moved.
public struct PairingPayload: Sendable, Equatable {
    /// Bumped when the wire format changes. A phone that sees a version it does
    /// not know must say so rather than guess at the fields.
    /// 2 — the JSON payload became `PairingWire`'s binary form, and
    /// `herdrPath` left the QR. Nothing had ever consumed a version 1 code, so
    /// the bump is a marker rather than a compatibility break.
    public static let currentVersion = 2

    public let version: Int
    public let username: String
    public let endpoints: [Endpoint]
    /// Raw 32-byte ed25519 seed of the single-use enrollment key.
    ///
    /// Raw, not an OpenSSH PEM: ~44 base64 characters against ~600, which is
    /// the difference between a QR that scans at arm's length and one that does
    /// not.
    public let enrollmentSeed: Data
    /// The host's host key in OpenSSH `<algorithm> <base64>` form.
    ///
    /// The full key, not a `SHA256:` fingerprint, because this is what the pin
    /// is compared against: `PinningHostKeyValidator` derives exactly this
    /// string via `String(openSSHPublicKey:)` and hands it to
    /// `KnownHostsStore`. A fingerprint could only be displayed, never matched,
    /// so carrying one would have made every paired connection fail its pin
    /// check. It costs about 30 bytes more in the QR.
    public let hostKey: String
    /// Display name for the peer. Cosmetic; identity is the host key.
    public let name: String

    public init(
        version: Int = PairingPayload.currentVersion,
        name: String,
        username: String,
        endpoints: [Endpoint],
        enrollmentSeed: Data,
        hostKey: String
    ) {
        self.version = version
        self.name = name
        self.username = username
        self.endpoints = endpoints
        self.enrollmentSeed = enrollmentSeed
        self.hostKey = hostKey
    }

    /// The enrollment key itself.
    public func enrollmentKey() throws -> SSHKeyPair {
        try SSHKeyPair(rawRepresentation: enrollmentSeed)
    }

    /// `SHA256:…`, as `ssh-keygen -l` prints it. For showing the user; the
    /// pin comparison uses `hostKey` itself.
    public var hostKeyFingerprint: String? {
        SSHPublicKeyLine(line: hostKey)?.fingerprint
    }
}
