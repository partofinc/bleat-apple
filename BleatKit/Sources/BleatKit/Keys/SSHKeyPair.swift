// `@preconcurrency` for Linux. On Apple platforms `Crypto` re-exports CryptoKit,
// whose `Curve25519.Signing.PrivateKey` is `Sendable`; swift-crypto's own
// implementation — what Linux gets — does not say so (3.15.1), though the key is
// an immutable value. Without this the console tool cannot build for Linux.
@preconcurrency import Crypto
import Foundation

/// An ed25519 key the app owns.
///
/// Phase 2 generates this on device and never moves the private half: the user
/// installs the *public* line on the host, the way any SSH key is adopted.
public struct SSHKeyPair: Sendable {
    public let privateKey: Curve25519.Signing.PrivateKey

    public init(privateKey: Curve25519.Signing.PrivateKey) {
        self.privateKey = privateKey
    }

    public init() {
        self.init(privateKey: Curve25519.Signing.PrivateKey())
    }

    /// Restores a key from its 32-byte raw representation.
    public init(rawRepresentation: Data) throws {
        self.init(privateKey: try Curve25519.Signing.PrivateKey(rawRepresentation: rawRepresentation))
    }

    public var rawRepresentation: Data { privateKey.rawRepresentation }

    /// The line to append to the host's `~/.ssh/authorized_keys`.
    ///
    /// SSH public keys are `<type> <base64 blob> <comment>`, where the blob is
    /// SSH wire format: each field is a 4-byte big-endian length followed by
    /// its bytes, here the type name and then the 32-byte public key.
    /// - Parameter comment: Trailing label. Sanitised, not trusted: a newline
    ///   would append a *second* entry when this is written to
    ///   `authorized_keys`, and a quote would break the shell instruction the
    ///   app shows for installing it.
    public func authorizedKeyLine(comment: String = "bleat") -> String {
        let encoded = publicKeyBlob.base64EncodedString()
        let safe = Self.sanitize(comment)
        return safe.isEmpty ? "\(Self.keyType) \(encoded)" : "\(Self.keyType) \(encoded) \(safe)"
    }

    /// Keeps a comment to one harmless token: no newlines, no quotes, no
    /// backslashes, and nothing that would split the line.
    static func sanitize(_ comment: String) -> String {
        let disallowed = CharacterSet(charactersIn: "'\"\\`$\n\r\t")
            .union(.newlines)
            .union(.controlCharacters)
        return comment
            .components(separatedBy: disallowed)
            .joined()
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "-")
    }

    /// The fingerprint `ssh-keygen -l` prints for this key.
    ///
    /// OpenSSH hashes the **whole wire-format blob**, not the bare 32-byte
    /// public key. Hashing the raw key instead produces a plausible-looking
    /// SHA256: string that matches nothing the user can see on the host, which
    /// makes it worse than showing no fingerprint at all.
    public var fingerprint: String {
        let digest = SHA256.hash(data: publicKeyBlob)
        let encoded = Data(digest).base64EncodedString()
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        return "SHA256:\(encoded)"
    }

    private static let keyType = "ssh-ed25519"

    /// SSH wire format: each field is a 4-byte big-endian length followed by
    /// its bytes — here the type name, then the 32-byte public key.
    private var publicKeyBlob: Data {
        var blob = Data()
        blob.append(Self.sshString(Data(Self.keyType.utf8)))
        blob.append(Self.sshString(privateKey.publicKey.rawRepresentation))
        return blob
    }

    private static func sshString(_ bytes: Data) -> Data {
        var out = Data()
        var length = UInt32(bytes.count).bigEndian
        withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
        out.append(bytes)
        return out
    }
}
