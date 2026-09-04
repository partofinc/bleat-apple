#if canImport(Security)
import Foundation
import Security

/// Stores the app's ed25519 private key in the Keychain.
///
/// Security.framework is on **both Apple platforms**, so macOS and iOS share
/// this file unbranched — the `canImport` guard is there for Linux, which has
/// no Keychain and will need a file-based store under `~/.bleat/` instead. The
/// item is `ThisDeviceOnly`: the private half is generated on the device and is
/// not meant to sync to iCloud or restore onto another one — a second device
/// gets its own key and its own line in `authorized_keys`.
public struct KeychainKeyStore: Sendable {
    private let service: String
    private let account: String

    public init(service: String = "team.partof.bleat.ssh", account: String = "default") {
        self.service = service
        self.account = account
    }

    /// The stored key, generating and saving one on first use.
    public func loadOrCreate() throws -> SSHKeyPair {
        if let existing = try load() { return existing }
        let created = SSHKeyPair()
        try save(created)
        return created
    }

    public func load() throws -> SSHKeyPair? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { throw KeychainError.unexpectedFormat }
            return try SSHKeyPair(rawRepresentation: data)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.status(status)
        }
    }

    /// Stores a key, refusing to overwrite one that already exists.
    ///
    /// The refusal matters: `load()` can return nil while an item *is* present
    /// under a different access group — after a team or provisioning-profile
    /// change, say. Silently replacing it would kill the `authorized_keys` line
    /// the user already installed, with no way to tell that had happened.
    /// Rotation is `replace(_:)`, which is a deliberate call.
    public func save(_ pair: SSHKeyPair) throws {
        let status = SecItemAdd(attributes(for: pair) as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            throw KeychainError.keyAlreadyExists
        default:
            throw KeychainError.status(status)
        }
    }

    /// Replaces the stored key. The old key's `authorized_keys` line becomes
    /// dead, so this is only for a rotation the user asked for.
    public func replace(with pair: SSHKeyPair) throws {
        // Delete then add, rather than SecItemUpdate: an update leaves the old
        // item's accessibility in place, so a key could quietly end up more
        // available than ThisDeviceOnly.
        try delete()
        try save(pair)
    }

    private func attributes(for pair: SSHKeyPair) -> [String: Any] {
        var attributes = baseQuery
        attributes[kSecValueData as String] = pair.rawRepresentation
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return attributes
    }

    /// Removes the key. The host's `authorized_keys` line becomes dead after
    /// this, so it is a deliberate act, not cleanup.
    public func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.status(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

public enum KeychainError: Error, Sendable, Equatable {
    case status(OSStatus)
    case unexpectedFormat
    /// An item exists but was not readable — usually a changed access group.
    /// Overwriting it would silently invalidate an installed public key.
    case keyAlreadyExists
}

extension KeychainError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .status(let code):
            let message = SecCopyErrorMessageString(code, nil) as String? ?? "unknown"
            return "keychain error \(code): \(message)"
        case .unexpectedFormat:
            return "keychain returned something that is not a key"
        case .keyAlreadyExists:
            return "a key is already stored but could not be read; refusing to overwrite it"
        }
    }
}

#else

// Linux port pending: no Keychain. The console tool does not reference this
// type — it keeps keys under `~/.bleat/`, like `HostRegistry` and
// `KnownHostsStore` — so nothing on the Linux path needs it yet.

#endif
