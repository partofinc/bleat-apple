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
        /// OpenSSH `<algorithm> <base64>` form — what `KnownHostsStore` pins.
        public let hostKey: String
        /// For display only.
        public var hostKeyFingerprint: String? { SSHPublicKeyLine(line: hostKey)?.fingerprint }
        public let herdrPath: String
    }

    /// Fallback host key files, in the order NIOSSH will negotiate them.
    ///
    /// Only consulted when `ssh-keyscan` cannot reach the port. Reading these
    /// is a guess: they are the *system* sshd's keys, and a host running sshd
    /// on another port — including the throwaway `/usr/sbin/sshd` this repo's
    /// own test procedure uses — presents a different key entirely.
    /// `ssh_host_rsa_key` is deliberately absent: NIOSSH does not speak
    /// `ssh-rsa` at all.
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
        guard let hostKey = readHostKey(port: port) else { throw PairingError.noSupportedHostKey }

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
            hostKey: hostKey.openSSHForm,
            herdrPath: herdrPath
        )
    }

    /// Finds `herdr` through a **login** shell.
    ///
    /// The question and the reading of its answer are `HerdrLookup`'s, in
    /// `BleatKit`, because the phone asks the same thing over SSH on first
    /// connect. Two copies of "which line of this output is the path" would
    /// drift, and the way they would drift — a profile banner ending up in the
    /// stored path — is silent until the first herdr call fails.
    func locateHerdr() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/sh"
        guard let output = run(shell, ["-lc", "command -v herdr"]) else { return nil }
        return HerdrLookup.path(inOutput: output)
    }

    /// The host key the phone will actually be shown.
    ///
    /// Asks the running sshd via `ssh-keyscan` rather than reading
    /// `/etc/ssh`, because the file on disk is only the *system* sshd's key.
    /// A host serving SSH on another port — including the throwaway
    /// `/usr/sbin/sshd` this repo's test procedure runs on 2222 — presents a
    /// different key, and pinning the wrong one makes the phone reject every
    /// connection as a host key mismatch with nothing pointing at the cause.
    ///
    /// Falls back to the files when nothing answers on the port, so `inspect`
    /// still reports something useful on a host whose sshd is down; the caller
    /// sees the same shape either way.
    func readHostKey(port: Int) -> SSHPublicKeyLine? {
        if let output = run("/usr/bin/ssh-keyscan", ["-T", "5", "-p", String(port), "127.0.0.1"]),
           let scanned = SSHPublicKeyLine.preferred(inKeyscanOutput: output) {
            return scanned
        }
        for path in Self.hostKeyFiles {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8),
                  let line = SSHPublicKeyLine(line: text), line.isNegotiable
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
        // Discard rather than pipe: an unread pipe fills at 64 KiB and blocks
        // the child forever, and a login shell's profile can be chatty on
        // stderr. Stdin is closed so a shell that turns interactive cannot sit
        // waiting at a prompt the user never sees.
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
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
