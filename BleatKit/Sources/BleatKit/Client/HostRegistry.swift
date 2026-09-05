import Foundation

/// A saved host: what `bleat hosts add dev user@10.0.0.5 --key …` records.
public struct HostEntry: Codable, Sendable, Identifiable, Hashable {
    public let name: String
    public let spec: String
    public let keyPath: String
    /// Absolute path to `herdr` when a non-login shell lacks it on `PATH`.
    public var herdrPath: String
    public var session: String?

    public var id: String { name }

    public init(name: String, spec: String, keyPath: String, herdrPath: String = "herdr", session: String? = nil) {
        self.name = name
        self.spec = spec
        self.keyPath = keyPath
        self.herdrPath = herdrPath
        self.session = session
    }

    public func host() throws -> SSHHost { try SSHHost(parsing: spec) }
}

/// Saved hosts on disk. Phase 2 moves the key into the Keychain; the console
/// tool keeps it under `~/.bleat/`.
public struct HostRegistry: Sendable {
    private let url: URL

    public init(url: URL) { self.url = url }

    /// `~/.bleat` — the console tool's. An app on iOS must pass a directory
    /// instead: `NSHomeDirectory()` there is the container's read-only root, so
    /// this path cannot be created. See `PeerRegistry.applicationSupport()`.
    public static func standard(
        directory: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".bleat")
    ) -> HostRegistry {
        HostRegistry(url: directory.appendingPathComponent("hosts.json"))
    }

    public func all() throws -> [HostEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return try JSONDecoder().decode([HostEntry].self, from: data)
    }

    public func entry(named name: String) throws -> HostEntry? {
        try all().first { $0.name == name }
    }

    /// Adds or replaces a host by name.
    public func save(_ entry: HostEntry) throws {
        var entries = try all().filter { $0.name != entry.name }
        entries.append(entry)
        entries.sort { $0.name < $1.name }
        try write(entries)
    }

    /// Removes a host.
    ///
    /// - Returns: `false` when no host had that name, so a typo can be reported
    ///   rather than silently confirmed.
    @discardableResult
    public func remove(named name: String) throws -> Bool {
        let entries = try all()
        let remaining = entries.filter { $0.name != name }
        guard remaining.count != entries.count else { return false }
        try write(remaining)
        return true
    }

    private func write(_ entries: [HostEntry]) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(entries).write(to: url, options: .atomic)
    }
}
