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
        // `main.swift` already rejects a malformed --endpoint, so this re-parse
        // cannot legitimately drop one. Checked rather than assumed: a silent
        // `compactMap` would put a QR in front of the user that quietly lacks
        // the one overlay address they asked for, and still look fine.
        let extra = options.endpoints.compactMap { Endpoint(string: $0, defaultPort: port) }
        guard extra.count == options.endpoints.count else {
            throw PairingFailure("an --endpoint could not be resolved against port \(port)")
        }
        let report = try HostInspector().inspect(port: port, extraEndpoints: extra)

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
        // Nothing to install if the user has already cancelled: the handler
        // has run, and installing now would put a key in the file that only the
        // deadline would remove.
        guard !cleanup.wasSignalled else {
            print("\nCancelled before the key was installed.")
            exit(130)
        }
        try shell(AuthorizedKeys.appendCommand(line: line), "installing the enrollment key")

        let payload = PairingPayload(
            name: report.name,
            username: report.username,
            endpoints: report.endpoints,
            enrollmentSeed: enrollment.rawRepresentation,
            hostKey: report.hostKey,
            herdrPath: report.herdrPath
        )

        let url = try payload.urlString()
        let title = "Pair with \(report.name) as \(report.username)"
        let subtitle = "host key \(report.hostKeyFingerprint ?? report.hostKey)"
        let footer = "Scan with the phone's camera — valid for \(describe(window)). Ctrl-C cancels."

        if let matrix = QRCodeGenerator.matrix(for: url),
           PairScreen.isInteractive,
           let terminal = PairScreen.size(),
           PairScreen.fits(matrix, in: terminal) {
            PairScreen.enter()
            cleanup.screenEntered()
            PairScreen.draw(matrix: matrix, title: title, subtitle: subtitle, footer: footer)
        } else {
            // No terminal, no room, or no generator: the link carries exactly
            // the same payload, so pairing still works — it is only the
            // convenience of scanning that is lost.
            print(title)
            print(subtitle)
            print("")
            print(url)
            if PairScreen.isInteractive,
               let matrix = QRCodeGenerator.matrix(for: url),
               let terminal = PairScreen.size(),
               !PairScreen.fits(matrix, in: terminal) {
                print("")
                print(PairScreen.tooSmallMessage(matrix, terminal))
            }
            print("")
            print("Waiting for the phone… (Ctrl-C cancels and removes the key)")
        }

        switch waitForRedemption(
            marker: marker, knownDevices: devicesBefore, until: deadline, cleanup: cleanup
        ) {
        case .redeemed:
            // The phone deletes the enrollment line itself as its last act, so
            // there may be nothing left to remove; `cleanup` is idempotent, and
            // it is also what takes the terminal back off the alternate screen.
            cleanup.run()
            print("Paired. The phone installed its own key and the enrollment key is gone.")
        case .cancelled:
            // `exit` below skips every `defer`, so cleanup is run explicitly.
            // It is idempotent and blocks until whichever path started first
            // has finished, so the key is gone before the process is.
            cleanup.run()
            print("\nCancelled. The enrollment key has been removed.")
            // 128 + SIGINT, the shell's convention for a signalled exit.
            exit(130)
        case .timedOut:
            cleanup.run()
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
            Thread.sleep(forTimeInterval: 0.1)
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
        private var signalled = false
        private var sources: [DispatchSourceSignal] = []
        /// A queue of its own, deliberately not `.main`.
        ///
        /// The poll loop blocks the main thread, and main-queue delivery
        /// happens to survive that only because `Process.waitUntilExit()` spins
        /// the run loop on each iteration. That is an accident of Foundation,
        /// not a property of this code: drop the subprocess from the loop and
        /// Ctrl-C would silently stop working, after the default disposition
        /// has already been replaced by `SIG_IGN`. A private queue removes the
        /// dependency entirely.
        private let queue = DispatchQueue(label: "team.partof.bleat.pair.signals")

        /// Set once the alternate screen is entered.
        ///
        /// Restoring belongs here rather than in a `defer` for the same reason
        /// the key removal does: `exit` skips defers, and the signal path exits.
        /// A cancelled pairing that left the terminal on the alternate screen
        /// would hide the user's shell until they typed `reset`.
        private var enteredAlternateScreen = false

        init(marker: AuthorizedKeys.Marker) { self.marker = marker }

        func screenEntered() { lock.withLock { enteredAlternateScreen = true } }

        var wasSignalled: Bool { lock.withLock { signalled } }

        /// `DispatchSourceSignal` rather than `signal(2)`: a C handler cannot
        /// capture the marker, and almost nothing is safe to call from inside
        /// one. The default disposition has to be ignored first, or the process
        /// dies before the source ever runs.
        func installSignalHandlers() {
            for sig in [SIGINT, SIGTERM, SIGHUP] {
                signal(sig, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: sig, queue: queue)
                source.setEventHandler { [self] in
                    // Removes the key immediately — waiting for the poll loop
                    // to notice would leave it installed for up to a tick.
                    // Reporting and the exit status are the caller's, because
                    // two paths racing to print produced the message twice and
                    // let main.swift's exit(0) beat this one's exit(130).
                    lock.withLock { signalled = true }
                    run()
                }
                source.resume()
                sources.append(source)
            }
        }

        /// Removes the key. Always — there is deliberately no "already done"
        /// latch.
        ///
        /// A latch looks like an obvious optimisation and is a correctness
        /// hole: a signal arriving between `installSignalHandlers` and the
        /// append finds nothing to remove, marks itself done, and then the key
        /// is installed a moment later and never removed again. Observed
        /// directly — a cancel 0.6s in exited 130 while leaving the enrollment
        /// key in the file. Removal is idempotent and takes milliseconds, so
        /// running it twice costs nothing and running it once too few costs the
        /// whole guarantee.
        ///
        /// The lock is held **across** the shell call, not just around a flag,
        /// so a second caller waits for the first to finish rather than
        /// returning early — and the caller that returns early is usually the
        /// one about to `exit`, which skips every `defer`.
        func run() {
            lock.lock()
            defer { lock.unlock() }
            // Terminal first, so anything printed afterwards lands on the
            // normal screen where the user will actually see it.
            if enteredAlternateScreen {
                PairScreen.leave()
                enteredAlternateScreen = false
            }
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

    /// Captures stderr and puts it in the error.
    ///
    /// CLAUDE.md's rule — never swallow stderr — earns its keep here: the
    /// failures users actually hit are an unwritable `~/.ssh`, a full disk or a
    /// failed `chmod`, and every one of them arrives as a bare non-zero status
    /// with the explanation on stderr. Reporting "exit 1" alone leaves nothing
    /// to act on.
    static func shellOutput(_ command: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()
        // Read before waiting: a full pipe buffer would deadlock the child.
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errorData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw PairingFailure(detail.isEmpty
                ? "exit \(process.terminationStatus)"
                : "exit \(process.terminationStatus): \(detail)")
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

#endif
