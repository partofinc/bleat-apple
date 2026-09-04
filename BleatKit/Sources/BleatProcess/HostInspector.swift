#if os(macOS)
import BleatKit
import Foundation

/// Reads everything `bleat pair` needs to describe this machine to a phone.
///
/// The parsing lives in `BleatKit` (`InterfaceAddresses`, `SSHPublicKeyLine`)
/// where it compiles for iOS and is tested against captured fixtures; this type
/// only runs the commands and reads the files. That split is why the awkward
/// parts — which addresses are usable, how a fingerprint is computed — are
/// covered by tests that touch nothing.
public struct HostInspector: Sendable {
    public struct Report: Sendable {
        /// Display name for the peer. Cosmetic; identity is the host key.
        public let name: String
        public let username: String
        public let endpoints: [Endpoint]
        public let hostKeyFingerprint: String
        public let herdrPath: String
    }

    /// Host key files in the order NIOSSH will negotiate them.
    ///
    /// The client's preference wins — it walks its own list and takes the first
    /// the server also offers — so ed25519 is what the phone sees whenever the
    /// host has one. `ssh_host_rsa_key` is deliberately absent: NIOSSH does not
    /// speak `ssh-rsa` at all.
    static let hostKeyFiles = [
        "/etc/ssh/ssh_host_ed25519_key.pub",
        "/etc/ssh/ssh_host_ecdsa_key.pub",
    ]

    public init() {}

    /// - Parameters:
    ///   - port: The port sshd is listening on.
    ///   - extraEndpoints: Endpoints detection cannot find. Overlays like
    ///     Twingate never tell the host its own resolvable name, so those are
    ///     supplied by the user rather than guessed at.
    public func inspect(port: Int = 22, extraEndpoints: [Endpoint] = []) throws -> Report {
        guard let herdrPath = locateHerdr() else { throw PairingError.herdrNotFound }
        guard let hostKey = readHostKey() else { throw PairingError.noSupportedHostKey }

        var endpoints: [Endpoint] = []
        if let local = trimmedOutput("/usr/sbin/scutil", ["--get", "LocalHostName"]) {
            endpoints.append(Endpoint(host: "\(local).local", port: port))
        }
        if let text = run("/sbin/ifconfig", []) {
            endpoints.append(contentsOf: InterfaceAddresses.endpoints(ifconfigOutput: text, port: port))
        }
        for endpoint in extraEndpoints where !endpoints.contains(endpoint) {
            endpoints.append(endpoint)
        }

        return Report(
            name: trimmedOutput("/usr/sbin/scutil", ["--get", "ComputerName"]) ?? NSUserName(),
            username: NSUserName(),
            endpoints: endpoints,
            hostKeyFingerprint: hostKey.fingerprint,
            herdrPath: herdrPath
        )
    }

    /// Finds `herdr` through a **login** shell.
    ///
    /// sshd runs an exec channel through a non-login shell, which does not read
    /// the profile that puts Homebrew on `PATH` — verified: a plain
    /// `zsh -c 'command -v herdr'` finds nothing while `zsh -lc` returns
    /// `/opt/homebrew/bin/herdr`. Resolving the absolute path here is what
    /// spares the phone from that problem entirely.
    func locateHerdr() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/sh"
        return trimmedOutput(shell, ["-lc", "command -v herdr"])
    }

    /// The first host key the phone could negotiate, in NIOSSH's own order.
    func readHostKey() -> SSHPublicKeyLine? {
        for path in Self.hostKeyFiles {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8),
                  let line = SSHPublicKeyLine(line: text)
            else { continue }
            return line
        }
        return nil
    }

    /// Runs a command and returns stdout, or nil when it exits non-zero.
    ///
    /// A missing optional tool is not an error here: `tailscale` and even
    /// `scutil` may be absent, and pairing should proceed with whatever
    /// endpoints were found rather than fail outright.
    func run(_ executable: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        // Read before waiting: a full pipe buffer would deadlock the child.
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// `run` with the trailing newline removed, and empty treated as absent —
    /// which is what every caller here wants.
    func trimmedOutput(_ executable: String, _ arguments: [String]) -> String? {
        guard let text = run(executable, arguments) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

#elseif os(Linux)

// Linux port pending: endpoint enumeration reads `ip addr` rather than
// `ifconfig`, and the host key path is the same. Deliberately empty rather than
// stubbed.

#endif
