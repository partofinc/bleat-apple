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

    /// Where the `tailscale` CLI lives, in the order worth trying.
    ///
    /// Absolute paths because `run` does not search `PATH`, deliberately: this
    /// runs as part of pairing, and resolving a tool through a user's `PATH`
    /// is a way to execute something else entirely. The App Store build ships
    /// the CLI inside the bundle; the standalone and Homebrew builds put a
    /// link in one of the two `bin` directories.
    static let tailscalePaths = [
        "/usr/local/bin/tailscale",
        "/opt/homebrew/bin/tailscale",
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
    ]

    /// Ask every `tailscale` on this machine until one answers.
    ///
    /// **Existing is not the same as working.** `brew install tailscale` puts a
    /// CLI in `/opt/homebrew/bin` that cannot reach the App Store app's
    /// sandboxed daemon, and both being installed is a common combination — so
    /// taking the first path that exists would run that one, get a non-zero
    /// exit, and silently drop the MagicDNS name while the bundled binary next
    /// in the list would have answered. Which is the whole point of this code,
    /// lost without a word.
    ///
    /// **Exiting 0 is not answering, and taking it for one was a regression.**
    /// An earlier refactor returned the first non-nil output, where the code
    /// before it kept going until a reply actually yielded endpoints. A
    /// Homebrew CLI that cannot reach the App Store app's daemon can exit
    /// cleanly reporting `NeedsLogin` or `Stopped`, so the weaker test stops
    /// there and never tries the bundled binary — dropping the MagicDNS name
    /// without a word, which is what this loop exists to prevent.
    /// `TailscaleStatus.isRunning` is the condition, and the shell command
    /// greps for the same `BackendState` so the two ends cannot disagree.
    ///
    /// `EndpointDiscovery.tailscaleStatusCommand` is this loop as a shell
    /// command, for the phone to run over an exec channel. The two have to keep
    /// agreeing — the order of the paths, the five-second bound, and now the
    /// success condition.
    func tailscaleStatusJSON() -> String? {
        for path in Self.tailscalePaths
        where FileManager.default.isExecutableFile(atPath: path) {
            // Bounded, because this sits on `bleat pair`'s critical path
            // *before* anything is printed: `run` blocks until the child closes
            // stdout, so a wedged or half-started `tailscaled` would hang
            // pairing at a blank terminal with no explanation. `readHostKey`
            // passes `ssh-keyscan -T 5` for the same hazard; `tailscale` has no
            // such flag, so the timeout is imposed from outside.
            guard let json = run(path, ["status", "--json"], timeout: 5),
                  TailscaleStatus.isRunning(statusJSON: Data(json.utf8))
            else { continue }
            return json
        }
        return nil
    }

    public init() {}

    /// - Parameters:
    ///   - port: The port sshd is listening on.
    ///   - extraEndpoints: Endpoints detection cannot find. Overlays like
    ///     Twingate never tell the host its own resolvable name, so those are
    ///     supplied by the user rather than guessed at.
    public func inspect(port: Int = 22, extraEndpoints: [Endpoint] = []) throws -> Report {
        guard let herdrPath = locateHerdr() else { throw PairingError.herdrNotFound }
        guard let hostKey = readHostKey(port: port) else { throw PairingError.noSupportedHostKey }

        // The ordering and the de-duplication are `EndpointDiscovery`'s, not
        // this type's, because the phone assembles the same three answers from
        // the same three commands run over SSH. Two copies of that would drift,
        // and the drift would be silent: a refresh would fold the peer into a
        // shape `bleat pair` would never have produced.
        var endpoints = EndpointDiscovery.endpoints(
            from: EndpointDiscovery.Outputs(
                localHostName: trimmedOutput("/usr/sbin/scutil", ["--get", "LocalHostName"]),
                ifconfig: run("/sbin/ifconfig", []),
                tailscaleStatusJSON: tailscaleStatusJSON()
            ),
            port: port
        )
        // Appended after, and deliberately outside what `EndpointDiscovery`
        // knows about: these are what detection *cannot* find, so they are not
        // part of the host's own report and a later refresh must not prune them
        // for being absent from it.
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
        // The command as well as the reading of it: `HerdrLookup.command`
        // resolves `$SHELL` itself, so this is the same question the phone
        // asks over SSH rather than a local restatement of it.
        guard let output = run("/bin/sh", ["-c", HerdrLookup.command]) else { return nil }
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
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval? = nil) -> String? {
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
        // A child that never exits would block the read below forever. Killing
        // it closes the pipe, which is what lets that read return at all.
        var watchdog: DispatchSourceTimer?
        if let timeout {
            let timer = DispatchSource.makeTimerSource(queue: .global())
            timer.schedule(deadline: .now() + timeout)
            timer.setEventHandler { if process.isRunning { process.terminate() } }
            timer.resume()
            watchdog = timer
        }
        // Read before waiting: a full pipe buffer would deadlock the child.
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog?.cancel()
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
