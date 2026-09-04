import Crypto
import Foundation

/// One line of an OpenSSH public key file: `<algorithm> <base64 blob> [comment]`.
///
/// Parsed rather than shelled out to `ssh-keygen -l`, so the fingerprint the QR
/// carries is computed the same way on every platform and the phone can check a
/// key it was handed without a subprocess.
public struct SSHPublicKeyLine: Sendable, Equatable {
    public let algorithm: String
    /// The decoded wire-format blob. What the fingerprint is taken over.
    public let blob: Data
    public let comment: String?

    /// Host key algorithms the phone can negotiate, in NIOSSH's own order.
    ///
    /// NIOSSH offers exactly these, and the client's order is what wins — it
    /// walks its own list and takes the first the server also has. Every modern
    /// OpenSSH ships an ed25519 host key, so that is the one the phone sees.
    /// `ssh-rsa` is absent because NIOSSH will not negotiate it at all, which
    /// is why an RSA-only host cannot be paired.
    public static let negotiableAlgorithms = [
        "ssh-ed25519",
        "ecdsa-sha2-nistp384",
        "ecdsa-sha2-nistp256",
        "ecdsa-sha2-nistp521",
    ]

    /// Whether the phone could negotiate this key.
    ///
    /// Checked against the parsed algorithm rather than a filename: a
    /// `ssh_host_ed25519_key.pub` containing an RSA line is unusual but would
    /// otherwise be accepted, and the mismatch would only appear as a failed
    /// handshake on the phone.
    public var isNegotiable: Bool { Self.negotiableAlgorithms.contains(algorithm) }

    /// The OpenSSH `<algorithm> <base64>` form, without any comment.
    ///
    /// This is what `KnownHostsStore` pins — `PinningHostKeyValidator` derives
    /// it via `String(openSSHPublicKey:)` — so it is the form that has to
    /// travel in the QR. A `SHA256:` fingerprint cannot be compared against a
    /// pin, only displayed.
    public var openSSHForm: String {
        "\(algorithm) \(blob.base64EncodedString())"
    }

    public init?(line: String) {
        // Split on any whitespace, not just spaces: a `.pub` file ends in a
        // newline, which would otherwise be read as a trailing comment.
        let fields = line.split(whereSeparator: \.isWhitespace)
        guard fields.count >= 2 else { return nil }
        guard let blob = Data(base64Encoded: String(fields[1])) else { return nil }
        // The algorithm is repeated as the first field *inside* the blob; a line
        // whose label disagrees with its payload is malformed, not merely
        // mislabelled, so it is rejected rather than trusted either way.
        guard let embedded = Self.firstField(of: blob),
              embedded == String(fields[0])
        else { return nil }

        self.algorithm = String(fields[0])
        self.blob = blob
        let rest = fields.dropFirst(2).joined(separator: " ")
        self.comment = rest.isEmpty ? nil : rest
    }

    /// The fingerprint `ssh-keygen -l` prints.
    ///
    /// Hashes the whole wire-format blob, as `SSHKeyPair.fingerprint` does.
    /// Hashing anything else yields a plausible `SHA256:` string that matches
    /// nothing the user can compare against, which is worse than no fingerprint.
    /// Rebuilds a key from its wire blob alone.
    ///
    /// The algorithm is not extra information: it is the blob's own first
    /// field, repeated in the text form. Reconstructing it here is what lets
    /// the QR carry the blob only and still produce the exact OpenSSH string
    /// the pin is compared against.
    public init?(blob: Data) {
        guard let algorithm = Self.firstField(of: blob) else { return nil }
        self.algorithm = algorithm
        self.blob = blob
        self.comment = nil
    }

    public var fingerprint: String {
        let digest = SHA256.hash(data: blob)
        let encoded = Data(digest).base64EncodedString()
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        return "SHA256:\(encoded)"
    }

    /// Reads the first SSH wire-format string: a 4-byte big-endian length
    /// followed by that many bytes.
    static func firstField(of blob: Data) -> String? {
        guard blob.count >= 4 else { return nil }
        let bytes = [UInt8](blob)
        let length = (Int(bytes[0]) << 24) | (Int(bytes[1]) << 16) | (Int(bytes[2]) << 8) | Int(bytes[3])
        guard length > 0, length <= bytes.count - 4 else { return nil }
        return String(bytes: bytes[4..<(4 + length)], encoding: .utf8)
    }
}

extension SSHPublicKeyLine {
    /// Picks the key the phone will negotiate out of `ssh-keyscan` output.
    ///
    /// Lines look like `127.0.0.1 ssh-ed25519 AAAA…`, with `#` banner lines
    /// mixed in. The host field is dropped: which address the scan used says
    /// nothing about the key.
    ///
    /// Preference follows `negotiableAlgorithms`, because that is the order
    /// NIOSSH will negotiate in — picking the first line instead would return
    /// whatever the server happened to list first and pin a key the phone never
    /// sees.
    public static func preferred(inKeyscanOutput output: String) -> SSHPublicKeyLine? {
        var found: [String: SSHPublicKeyLine] = [:]
        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 3 else { continue }
            let keyLine = fields.dropFirst().joined(separator: " ")
            guard let parsed = SSHPublicKeyLine(line: keyLine) else { continue }
            found[parsed.algorithm] = parsed
        }
        for algorithm in negotiableAlgorithms {
            if let match = found[algorithm] { return match }
        }
        return nil
    }
}
