#if os(macOS)
import BleatKit
import Foundation
import Testing

/// Runs a command the way the host would: a real `/bin/sh`, with `HOME` moved
/// somewhere disposable.
///
/// The point is to take the command strings out of the realm of "they look
/// right". Every one of them is greps and redirections against the user's
/// `authorized_keys`, and the failure mode is not an exception — it is a file
/// that still exists and no longer authenticates anything.
struct LocalShell: ShellRunner {
    let home: URL
    /// Overrides `SHELL`, so a test can describe a host that does not have
    /// herdr.
    ///
    /// `PATH` cannot do it: `/etc/profile` runs `path_helper`, which rebuilds
    /// `PATH` from `/etc/paths.d` — and Homebrew installs a file there — so a
    /// login shell puts `/opt/homebrew/bin` back whatever it was handed. The
    /// only way to describe a host without herdr on this machine is to supply
    /// the login shell itself.
    var loginShell: String?

    func run(shell command: String) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        // The lookup asks `$SHELL -lc`, and the scratch home's `.profile` is
        // written for `sh`. Pinning it also keeps the developer's own shell
        // configuration out of the test.
        environment["SHELL"] = loginShell ?? "/bin/sh"
        process.environment = environment

        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ShellError(
                command: command,
                exitCode: process.terminationStatus,
                stderr: String(decoding: stderr, as: UTF8.self)
            )
        }
        return String(decoding: stdout, as: UTF8.self)
    }
}

@Suite("The pairing swap, against a real shell")
struct EnrollmentShellTests {

    /// A home directory with a `herdr` on the login shell's PATH, a chatty
    /// profile, and an `authorized_keys` holding a key the user put there.
    private func scratchHome(withHerdr: Bool = true) throws -> URL {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bleat-enroll-\(UUID().uuidString)")
        let bin = home.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)

        if withHerdr {
            let herdr = bin.appendingPathComponent("herdr")
            try "#!/bin/sh\necho stub\n".write(to: herdr, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: herdr.path)
        }

        // Profiles print things. A banner here is not decoration: taking the
        // whole of stdout would store "Welcome back!" as part of the path.
        try "echo 'Welcome back!'\nPATH=\(bin.path):$PATH\n"
            .write(to: home.appendingPathComponent(".profile"), atomically: true, encoding: .utf8)
        return home
    }

    private func authorizedKeys(in home: URL) throws -> [String] {
        let path = home.appendingPathComponent(".ssh/authorized_keys")
        guard let text = try? String(contentsOf: path, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }

    /// The whole sequence, end to end, against real `grep`, real `mktemp` and a
    /// real file — with a key the user installed themselves sitting in it.
    @Test("the enrollment key is swapped for a device key, and nothing else moves")
    func swap() async throws {
        let home = try scratchHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let shell = LocalShell(home: home)

        // A key the user put there. `+` in the blob is deliberate: it is an ERE
        // metacharacter, and an unescaped pattern built from a *different* key
        // could match this line and delete it.
        let usersKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMhKfcrGJN9TJkeFBij/SoJie+EkZFSkE0zVCLVZbsnj robin@laptop"
        _ = try await shell.run(shell: AuthorizedKeys.appendCommand(line: usersKey))

        let enrollment = SSHKeyPair()
        let marker = AuthorizedKeys.enrollmentMarker()
        let enrollmentLine = AuthorizedKeys.enrollmentLine(
            publicKeyLine: enrollment.authorizedKeyLine(comment: ""),
            marker: marker,
            expiresAt: Date().addingTimeInterval(360)
        )
        _ = try await shell.run(shell: AuthorizedKeys.appendCommand(line: enrollmentLine))
        #expect(try authorizedKeys(in: home).count == 2)

        let device = SSHKeyPair()
        // The local shell stands in for both sessions: this suite is about the
        // command strings against a real file, and the "does sshd accept it"
        // half needs an sshd, which the SSH end-to-end run covers.
        let result = try await Enrollment.redeem(
            deviceKey: device, enrollmentKey: enrollment, on: shell, openDeviceSession: { shell }
        )

        let lines = try authorizedKeys(in: home)
        #expect(result.herdrPath == home.appendingPathComponent("bin/herdr").path)
        #expect(lines.contains(usersKey))
        #expect(lines.contains { $0.hasSuffix(result.deviceMarker) })
        #expect(!lines.contains { $0.contains(marker.value) })
        #expect(lines.count == 2)
    }

    /// `bleat pair` calls the pairing done when the enrollment line is gone
    /// **and** a new `bleat-device-` marker has appeared. If the phone's line
    /// did not match that grep, pairing would work and the tool would time out
    /// anyway — so the host's own command is what checks it here.
    @Test("the host's redemption check sees the new device key")
    func hostSeesRedemption() async throws {
        let home = try scratchHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let shell = LocalShell(home: home)

        let enrollment = SSHKeyPair()
        let marker = AuthorizedKeys.enrollmentMarker()
        _ = try await shell.run(shell: AuthorizedKeys.appendCommand(
            line: AuthorizedKeys.enrollmentLine(
                publicKeyLine: enrollment.authorizedKeyLine(comment: ""),
                marker: marker,
                expiresAt: Date().addingTimeInterval(360)
            )
        ))

        let before = try await shell.run(shell: AuthorizedKeys.listDeviceMarkersCommand())
        let result = try await Enrollment.redeem(
            deviceKey: SSHKeyPair(), enrollmentKey: enrollment, on: shell, openDeviceSession: { shell }
        )
        let after = try await shell.run(shell: AuthorizedKeys.listDeviceMarkersCommand())

        let gained = Set(after.split(separator: "\n").map(String.init))
            .subtracting(before.split(separator: "\n").map(String.init))
        #expect(gained == [result.deviceMarker])

        let stillThere = try await shell.run(shell: AuthorizedKeys.containsCommand(marker: marker))
        #expect(stillThere.trimmingCharacters(in: .whitespacesAndNewlines) == "no")
    }

    /// sshd's `StrictModes` makes it **ignore** `authorized_keys` when the file
    /// or `~/.ssh` is group- or world-writable, silently. A pairing that left
    /// the file at the umask default would look perfect and authenticate
    /// nothing.
    @Test("the file sshd will read has the permissions sshd insists on")
    func permissions() async throws {
        let home = try scratchHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let shell = LocalShell(home: home)

        let enrollment = SSHKeyPair()
        _ = try await shell.run(shell: AuthorizedKeys.appendCommand(
            line: enrollment.authorizedKeyLine(comment: "")
        ))
        _ = try await Enrollment.redeem(
            deviceKey: SSHKeyPair(), enrollmentKey: enrollment, on: shell, openDeviceSession: { shell }
        )

        let manager = FileManager.default
        let ssh = home.appendingPathComponent(".ssh")
        let file = ssh.appendingPathComponent("authorized_keys")
        #expect(try manager.attributesOfItem(atPath: ssh.path)[.posixPermissions] as? Int == 0o700)
        #expect(try manager.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
    }

    /// `authorized_keys` files written by hand frequently lack a trailing
    /// newline. Without the guard the new key is glued onto the end of the last
    /// one, which kills **both** — the user's key stops working and the new
    /// device never starts.
    @Test("a file with no trailing newline does not swallow the next key")
    func appendsOnItsOwnLine() async throws {
        let home = try scratchHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let shell = LocalShell(home: home)

        let ssh = home.appendingPathComponent(".ssh")
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        let usersKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMhKfcrGJN9TJkeFBij/SoJie+EkZFSkE0zVCLVZbsnj robin@laptop"
        try usersKey.write(   // no trailing newline, deliberately
            to: ssh.appendingPathComponent("authorized_keys"), atomically: true, encoding: .utf8
        )

        let enrollment = SSHKeyPair()
        _ = try await shell.run(shell: AuthorizedKeys.appendCommand(
            line: enrollment.authorizedKeyLine(comment: "")
        ))
        _ = try await Enrollment.redeem(
            deviceKey: SSHKeyPair(), enrollmentKey: enrollment, on: shell, openDeviceSession: { shell }
        )

        let lines = try authorizedKeys(in: home)
        #expect(lines.contains(usersKey))
        #expect(lines.count == 2)
    }

    /// `command -v` exits 1 when it finds nothing, and the login shell exits
    /// with it — so without the `|| true` in `HerdrLookup.command` a host
    /// without herdr produces a *failed command*, and the user is told
    /// "the host rejected a command (exit 1)" instead of what is wrong. The
    /// guard for `herdrNotFound` was unreachable against a real shell.
    @Test("a host without herdr says so, rather than failing the command")
    func herdrMissingOnARealShell() async throws {
        let home = try scratchHome(withHerdr: false)
        defer { try? FileManager.default.removeItem(at: home) }
        // A "login shell" with a PATH of its own, standing in for a host where
        // herdr is simply not installed.
        let stub = home.appendingPathComponent("bin/login-shell")
        try "#!/bin/sh\nPATH=/usr/bin:/bin\nexport PATH\nshift\nexec /bin/sh -c \"$1\"\n"
            .write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        let shell = LocalShell(home: home, loginShell: stub.path)

        // The command itself must succeed and answer nothing.
        let output = try await shell.run(shell: HerdrLookup.command)
        #expect(HerdrLookup.path(inOutput: output) == nil)

        let enrollment = SSHKeyPair()
        _ = try await shell.run(shell: AuthorizedKeys.appendCommand(
            line: enrollment.authorizedKeyLine(comment: "")
        ))
        await #expect(throws: PairingError.herdrNotFound) {
            try await Enrollment.redeem(
                deviceKey: SSHKeyPair(), enrollmentKey: enrollment, on: shell,
                openDeviceSession: { shell }
            )
        }
        // And nothing was written on the way to finding out.
        #expect(try authorizedKeys(in: home).count == 1)
    }

    /// Re-pairing a phone that is already paired rewrites its line. Doing that
    /// as a removal followed by an append would leave a window with the phone's
    /// only durable credential missing from the file.
    @Test("re-pairing leaves exactly one line for this device")
    func rePairingLeavesOneLine() async throws {
        let home = try scratchHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let shell = LocalShell(home: home)

        let usersKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMhKfcrGJN9TJkeFBij/SoJie+EkZFSkE0zVCLVZbsnj robin@laptop"
        _ = try await shell.run(shell: AuthorizedKeys.appendCommand(line: usersKey))

        // This device, from an earlier pairing, under an older marker.
        let device = SSHKeyPair()
        let oldMarker = try #require(AuthorizedKeys.deviceMarker(id: "0000000000000000"))
        _ = try await shell.run(shell: AuthorizedKeys.appendCommand(
            line: device.authorizedKeyLine(comment: oldMarker.value)
        ))

        let enrollment = SSHKeyPair()
        _ = try await shell.run(shell: AuthorizedKeys.appendCommand(
            line: enrollment.authorizedKeyLine(comment: "")
        ))

        let result = try await Enrollment.redeem(
            deviceKey: device, enrollmentKey: enrollment, on: shell, openDeviceSession: { shell }
        )

        let lines = try authorizedKeys(in: home)
        #expect(lines.contains(usersKey))
        #expect(lines.filter { $0.contains("bleat-device-") }.count == 1)
        #expect(lines.contains { $0.hasSuffix(result.deviceMarker) })
        #expect(!lines.contains { $0.contains(oldMarker.value) })
        #expect(lines.count == 2)
    }
}

#endif
