import Foundation

/// A host as the console tool spells it: `user@host` or `user@host:port`.
///
/// Phase 1 reads nothing from `~/.ssh/config`; everything is explicit.
public struct SSHHost: Sendable, Hashable, Codable {
    public let username: String
    public let hostname: String
    public let port: Int

    public init(username: String, hostname: String, port: Int = 22) {
        self.username = username
        self.hostname = hostname
        self.port = port
    }

    /// Parses `user@host`, `user@host:port`, or `user@[ipv6]:port`.
    ///
    /// A bare IPv6 literal (`user@fe80::1`) is accepted and takes the default
    /// port; brackets are required to give one an explicit port.
    public init(parsing spec: String) throws {
        guard let at = spec.lastIndex(of: "@") else {
            throw SSHHostParseError.missingUser(spec)
        }
        let user = String(spec[spec.startIndex..<at])
        var rest = String(spec[spec.index(after: at)...])
        guard !user.isEmpty, !rest.isEmpty else {
            throw SSHHostParseError.malformed(spec)
        }

        var parsedPort = 22

        if rest.hasPrefix("[") {
            // Bracketed IPv6: [fe80::1] or [fe80::1]:2222.
            guard let close = rest.firstIndex(of: "]") else { throw SSHHostParseError.malformed(spec) }
            let inner = String(rest[rest.index(after: rest.startIndex)..<close])
            let after = rest[rest.index(after: close)...]
            if !after.isEmpty {
                guard after.hasPrefix(":"), let value = Int(after.dropFirst()) else {
                    throw SSHHostParseError.malformed(spec)
                }
                guard (1...65535).contains(value) else { throw SSHHostParseError.badPort(spec) }
                parsedPort = value
            }
            rest = inner
        } else if rest.filter({ $0 == ":" }).count > 1 {
            // A bare IPv6 literal is all colons and has no port. Splitting on
            // the last one would read `fe80::1` as host `fe80:` on port 1.
        } else if let colon = rest.lastIndex(of: ":"),
                  let value = Int(rest[rest.index(after: colon)...]) {
            guard (1...65535).contains(value) else { throw SSHHostParseError.badPort(spec) }
            parsedPort = value
            rest = String(rest[rest.startIndex..<colon])
        }
        guard !rest.isEmpty else { throw SSHHostParseError.malformed(spec) }

        self.init(username: user, hostname: rest, port: parsedPort)
    }

    /// How this host is keyed in the known-hosts store.
    public var pinKey: String { "\(hostname):\(port)" }

    public var description: String {
        port == 22 ? "\(username)@\(hostname)" : "\(username)@\(hostname):\(port)"
    }
}

public enum SSHHostParseError: Error, Sendable, Equatable {
    case missingUser(String)
    case malformed(String)
    case badPort(String)
}
