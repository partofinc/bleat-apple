#if os(macOS)   // see main.swift: the console tool is macOS-only
import BleatKit
import Foundation

/// `bleat hosts …` — the saved-host registry under `~/.bleat/`.
enum Hosts {
    static func run(registry: HostRegistry, options: Options) throws {
        guard let action = options.positional.first else {
            throw Failure("hosts needs add, list or remove")
        }
        let rest = Array(options.positional.dropFirst())

        switch action {
        case "add":
            guard rest.count >= 2 else {
                throw Failure("hosts add <name> <user@host[:port]> --key PATH")
            }
            guard let key = options.keyPath else {
                throw Failure("hosts add needs --key PATH")
            }
            // Fail now, not on first connect, if the spec or key is unusable.
            _ = try SSHHost(parsing: rest[1])
            let expanded = (key as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else {
                throw Failure("no key at \(expanded)")
            }
            _ = try SSHTransport.privateKey(atPath: expanded)

            try registry.save(
                HostEntry(
                    name: rest[0],
                    spec: rest[1],
                    keyPath: key,
                    herdrPath: options.herdrPath ?? "herdr",
                    session: options.session
                )
            )
            print("added \(rest[0]) → \(rest[1])")

        case "list":
            let entries = try registry.all()
            if entries.isEmpty { print("no hosts yet"); return }
            for entry in entries {
                let session = entry.session.map { "  --session \($0)" } ?? ""
                print("\(entry.name)  \(entry.spec)  key=\(entry.keyPath)\(session)")
            }

        case "remove":
            guard let name = rest.first else { throw Failure("hosts remove <name>") }
            guard try registry.remove(named: name) else {
                throw Failure("no host named \(name)")
            }
            print("removed \(name)")

        default:
            throw Failure("unknown hosts action: \(action)")
        }
    }
}

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Turns transport failures into something a person can act on.
enum Describe {
    static func transport(_ error: TransportError) -> String {
        switch error {
        case .hostKeyMismatch(let expected, let actual):
            return """
            host key changed — refusing to connect.
              pinned:   \(expected)
              offered:  \(actual)
            If this was an intentional rekey, remove the line for this host from
            ~/.bleat/known_hosts and connect again.
            """
        case .authenticationFailed(let detail):
            return "authentication failed: \(detail)"
        case .connectionFailed(let detail):
            return "could not connect: \(detail)"
        case .channelClosed:
            return "the channel closed"
        case .notConnected:
            return "not connected"
        case .oversizedRecord(let limit):
            return "host sent a record larger than \(limit) bytes without a newline"
        }
    }
}

#endif
