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

    /// The algorithm the phone will actually negotiate.
    ///
    /// NIOSSH offers exactly `ssh-ed25519`, `ecdsa-sha2-nistp384`,
    /// `ecdsa-sha2-nistp256`, `ecdsa-sha2-nistp521`, in that order, and the
    /// client's order is what wins — it walks its own list and takes the first
    /// the server also has. Every modern OpenSSH ships an ed25519 host key, so
    /// this is the one the phone sees. It is also why an RSA-only host cannot
    /// be paired at all: NIOSSH will not negotiate `ssh-rsa`.
    public static let negotiatedHostKeyAlgorithm = "ssh-ed25519"

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
