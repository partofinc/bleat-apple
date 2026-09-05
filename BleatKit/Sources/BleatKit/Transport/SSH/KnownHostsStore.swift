import Foundation

/// Persists pinned host keys, one line per host: `host:port <base64 key>`.
///
/// Trust on first use. A host we have never seen is pinned; a host whose key
/// no longer matches is a hard error, never a prompt — that is the whole point
/// of pinning.
public struct KnownHostsStore: Sendable {
    private let url: URL

    public init(url: URL) { self.url = url }

    /// Default location for the console tool: `~/.bleat/known_hosts`.
    /// `~/.bleat` — the console tool's. An app on iOS must pass a directory
    /// instead: `NSHomeDirectory()` there is the container's read-only root, so
    /// this path cannot be created. See `PeerRegistry.applicationSupport()`.
    public static func standard(
        directory: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".bleat")
    ) -> KnownHostsStore {
        KnownHostsStore(url: directory.appendingPathComponent("known_hosts"))
    }

    /// The pinned key for a host, or nil if it has never been seen.
    public func pinnedKey(for host: String) throws -> String? {
        try entries()[host]
    }

    /// Records a key for a host not seen before.
    ///
    /// Throws `TransportError.hostKeyMismatch` rather than overwriting a
    /// different pinned key: replacing a pin is a deliberate act, not a
    /// side effect of connecting.
    public func pin(_ key: String, for host: String) throws {
        var current = try entries()
        if let existing = current[host], existing != key {
            throw TransportError.hostKeyMismatch(expected: existing, actual: key)
        }
        guard current[host] == nil else { return }
        current[host] = key
        try write(current)
    }

    /// Drops a pin so the next connection re-pins. For an intentional rekey.
    public func forget(_ host: String) throws {
        var current = try entries()
        guard current.removeValue(forKey: host) != nil else { return }
        try write(current)
    }

    public func allEntries() throws -> [String: String] { try entries() }

    // MARK: - Storage

    private func entries() throws -> [String: String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var result: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            result[String(parts[0])] = String(parts[1])
        }
        return result
    }

    private func write(_ entries: [String: String]) throws {
        let body = entries
            .sorted { $0.key < $1.key }
            .map { "\($0.key) \($0.value)" }
            .joined(separator: "\n")

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try (body + "\n").write(to: url, atomically: true, encoding: .utf8)
        // Written atomically, so permissions are set after the replace.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
