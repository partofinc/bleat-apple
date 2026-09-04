#if os(macOS)   // see main.swift: the console tool is macOS-only
import BleatKit
import BleatProcess
import Darwin
import Dispatch
import Foundation

/// `bleat pair` — hands a phone everything it needs, once.
///
/// The enrollment key this installs must not outlive the pairing, and there are
/// three separate reasons it might try to. Each gets its own defence:
///
/// 1. **The tool exits, normally or by error.** `defer` removes the line.
/// 2. **The user cancels, or the terminal closes.** `SIGINT`, `SIGTERM` and
///    `SIGHUP` are trapped and run the same removal.
/// 3. **The tool cannot run at all** — `SIGKILL`, a panic, a power cut. Nothing
///    in this process can help, so the line carries `expiry-time` and **sshd**
///    refuses the key once it passes. A later `bleat pair` also sweeps whatever
///    a previous run left behind.
///
/// Only the third layer is unconditional, which is why it is not optional.
enum Pair {
    /// How long the QR is good for, and how long the tool waits.
    static let defaultWindow: TimeInterval = 5 * 60

    /// Extra life on the sshd-side deadline, beyond the tool's own.
    ///
    /// A phone that connects a second before the window closes is still
    /// mid-swap when it ends; expiring the key underneath it would strand the
    /// pairing with the device key half-installed. The tool removes the line at
    /// its own deadline anyway, so this only applies when the tool is gone.
    static let expiryGrace: TimeInterval = 60

    static func run(options: Options) throws {
        let port = options.port ?? 22
        let report = try HostInspector().inspect(
            port: port,
            extraEndpoints: options.endpoints.compactMap { Endpoint(string: $0, defaultPort: port) }
        )

        guard !report.endpoints.isEmpty else {
            throw PairingFailure("no reachable address found for this host; pass one with --endpoint")
        }

        // A previous run killed with SIGKILL cannot have cleaned up after
        // itself. Clear anything it left before adding one more.
        try shell(AuthorizedKeys.sweepEnrollmentsCommand(), "sweeping old enrollment keys")

        let enrollment = SSHKeyPair()
        let marker = AuthorizedKeys.enrollmentMarker()
        let window = options.timeout.map(TimeInterval.init) ?? defaultWindow
        let deadline = Date().addingTimeInterval(window)

        let line = AuthorizedKeys.enrollmentLine(
            publicKeyLine: enrollment.authorizedKeyLine(comment: ""),
            marker: marker,
            expiresAt: deadline.addingTimeInterval(expiryGrace)
        )

        let cleanup = Cleanup(marker: marker)
        cleanup.installSignalHandlers()
        defer { cleanup.run() }

        // Recorded before the phone can act, so redemption is judged on a new
        // key appearing rather than on any device key existing.
        let devicesBefore = deviceMarkers()
        try shell(AuthorizedKeys.appendCommand(line: line), "installing the enrollment key")

        let payload = PairingPayload(
            name: report.name,
            username: report.username,
            endpoints: report.endpoints,
            enrollmentSeed: enrollment.rawRepresentation,
            hostKey: report.hostKey,
            herdrPath: report.herdrPath
        )

        print("Pair with \(report.name) as \(report.username) — valid for \(describe(window))")
        print("host key  \(report.hostKeyFingerprint ?? report.hostKey)")
        print("")
        print(try payload.urlString())
        print("")
        print("Waiting for the phone… (Ctrl-C cancels and removes the key)")

        switch waitForRedemption(
            marker: marker, knownDevices: devicesBefore, until: deadline, cleanup: cleanup
        ) {
        case .redeemed:
            // The phone deletes the enrollment line itself as its last act, so
            // there may be nothing left to remove; `cleanup` is idempotent.
            print("Paired. The phone installed its own key and the enrollment key is gone.")
        case .cancelled:
            print("\nCancelled. The enrollment key has been removed.")
        case .timedOut:
            print("Timed out after \(describe(window)). The enrollment key has been removed.")
        }
    }

    /// Minutes read wrong under a minute: a 30-second window announced itself
    /// as "0 minutes".
    static func describe(_ interval: TimeInterval) -> String {
        let seconds = Int(interval.rounded())
        if seconds < 60 { return "\(seconds) second\(seconds == 1 ? "" : "s")" }
        let minutes = seconds / 60
        return "\(minutes) minute\(minutes == 1 ? "" : "s")"
    }

    enum Outcome { case redeemed, cancelled, timedOut }

    /// Polls until the phone swaps its own key in, the window closes, or the
    /// user cancels.
    ///
    /// Success is **both** halves: a device key present *and* the enrollment
    /// line gone. Treating the disappearance alone as success would call a
    /// hand-edited `authorized_keys` a successful pairing.
    static func waitForRedemption(
        marker: AuthorizedKeys.Marker,
        knownDevices: Set<String>,
        until deadline: Date,
        cleanup: Cleanup
    ) -> Outcome {
        while Date() < deadline {
            if cleanup.wasSignalled { return .cancelled }
            let enrollmentGone = (try? shellOutput(AuthorizedKeys.containsCommand(marker: marker)))?
                .trimmingCharacters(in: .whitespacesAndNewlines) == "no"
            if enrollmentGone, !deviceMarkers().subtracting(knownDevices).isEmpty { return .redeemed }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return cleanup.wasSignalled ? .cancelled : .timedOut
    }

    static func deviceMarkers() -> Set<String> {
        guard let output = try? shellOutput(AuthorizedKeys.listDeviceMarkersCommand()) else { return [] }
        return Set(output.split(separator: "\n").map(String.init).filter { !$0.isEmpty })
    }

    // MARK: - Cleanup

    /// Removes the enrollment line exactly once, from whichever path gets there
    /// first: a signal, the `defer`, or an error unwinding.
    final class Cleanup: @unchecked Sendable {
        private let marker: AuthorizedKeys.Marker
        private let lock = NSLock()
        private var done = false
        private var signalled = false
        private var sources: [DispatchSourceSignal] = []

        init(marker: AuthorizedKeys.Marker) { self.marker = marker }

        var wasSignalled: Bool { lock.withLock { signalled } }

        /// `DispatchSourceSignal` rather than `signal(2)`: a C handler cannot
        /// capture the marker, and almost nothing is safe to call from inside
        /// one. The default disposition has to be ignored first, or the process
        /// dies before the source ever runs.
        func installSignalHandlers() {
            for sig in [SIGINT, SIGTERM, SIGHUP] {
                signal(sig, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
                source.setEventHandler { [self] in
                    lock.withLock { signalled = true }
                    run()
                    // The window is gone; leaving would only spin the poll loop.
                    print("\nCancelled. The enrollment key has been removed.")
                    exit(130)
                }
                source.resume()
                sources.append(source)
            }
        }

        func run() {
            let shouldRun = lock.withLock {
                if done { return false }
                done = true
                return true
            }
            guard shouldRun else { return }
            _ = try? shellOutput(AuthorizedKeys.removeCommand(marker: marker))
        }
    }

    // MARK: - Shell

    struct PairingFailure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    /// Runs the very command strings the phone will run, rather than a local
    /// reimplementation, so both sides exercise one definition of what a Bleat
    /// entry is and how it is removed.
    @discardableResult
    static func shell(_ command: String, _ what: String? = nil) throws -> String {
        do { return try shellOutput(command) }
        catch { throw PairingFailure("\(what ?? "command") failed: \(error)") }
    }

    static func shellOutput(_ command: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw PairingFailure("exit \(process.terminationStatus)")
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

#endif
