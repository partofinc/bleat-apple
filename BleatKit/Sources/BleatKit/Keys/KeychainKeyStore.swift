import Foundation
import Security

/// Stores the app's ed25519 private key in the Keychain.
///
/// Security.framework is on both platforms, so this needs no `#if`. The item is
/// `ThisDeviceOnly`: the private half is generated on the device and is not
/// meant to sync to iCloud or restore onto another one — a second device gets
/// its own key and its own line in `authorized_keys`.
public struct KeychainKeyStore: Sendable {
    private let service: String
    private let account: String

    public init(service: String = "dev.herdr.bleat.ssh", account: String = "default") {
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

    public func save(_ pair: SSHKeyPair) throws {
        var attributes = baseQuery
        attributes[kSecValueData as String] = pair.rawRepresentation
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(attributes as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            // Replace rather than fail: re-adding is how a rotation lands.
            let update = [kSecValueData as String: pair.rawRepresentation] as CFDictionary
            let updateStatus = SecItemUpdate(baseQuery as CFDictionary, update)
            guard updateStatus == errSecSuccess else { throw KeychainError.status(updateStatus) }
        default:
            throw KeychainError.status(status)
        }
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
}

extension KeychainError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .status(let code):
            let message = SecCopyErrorMessageString(code, nil) as String? ?? "unknown"
            return "keychain error \(code): \(message)"
        case .unexpectedFormat:
            return "keychain returned something that is not a key"
        }
    }
}
