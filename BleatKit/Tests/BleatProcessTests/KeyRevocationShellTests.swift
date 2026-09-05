#if os(macOS)
import BleatKit
import Foundation
import Testing

/// `bleat keys` against a real `/bin/sh`, a real `grep` and a real file.
///
/// The parser has its own tests; this suite is about the commands. Listing and
/// revoking are the two operations that decide whether a user can see and undo
/// what pairing did, and both are greps and redirections over the file that
/// decides who may log in. "The string looks right" is not a standard that
/// covers a command whose failure mode is a key that still works, or an
/// `authorized_keys` with the user's own key missing from it.
@Suite("bleat keys, against a real shell")
struct KeyRevocationShellTests {

    /// A home holding one key the user installed themselves, one paired device,
    /// and one leftover enrollment key that has already expired — which is
    /// exactly what a Mac looks like after a phone is paired and an earlier
    /// `bleat pair` was killed.
    private struct Scratch {
        let home: URL
        let shell: LocalShell
        let userKey: SSHKeyPair
        let deviceKey: SSHKeyPair
        let deviceMarker: AuthorizedKeys.Marker
        let enrollmentMarker: AuthorizedKeys.Marker
    }

    private func scratch() async throws -> Scratch {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bleat-keys-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let shell = LocalShell(home: home)

        let userKey = SSHKeyPair()
        let deviceKey = SSHKeyPair()
        let deviceMarker = AuthorizedKeys.deviceMarker()
        let enrollmentMarker = AuthorizedKeys.enrollmentMarker()

        _ = try await shell.run(shell: AuthorizedKeys.appendCommand(
            line: userKey.authorizedKeyLine(comment: "ravil@rawillk.air")
        ))
        _ = try await shell.run(shell: AuthorizedKeys.appendCommand(
            line: deviceKey.authorizedKeyLine(comment: deviceMarker.value)
        ))
        _ = try await shell.run(shell: AuthorizedKeys.appendCommand(
            line: AuthorizedKeys.enrollmentLine(
                publicKeyLine: SSHKeyPair().authorizedKeyLine(comment: ""),
                marker: enrollmentMarker,
                expiresAt: Date().addingTimeInterval(-60)
            )
        ))
        return Scratch(
            home: home,
            shell: shell,
            userKey: userKey,
            deviceKey: deviceKey,
            deviceMarker: deviceMarker,
            enrollmentMarker: enrollmentMarker
        )
    }

    /// The base64 field of a key, for asking whether a line is *this* key.
    /// `publicKeyBlob` is private on `SSHKeyPair`, and the text form is what
    /// the file holds anyway.
    private func blob(of key: SSHKeyPair) -> String {
        String(key.authorizedKeyLine(comment: "").split(whereSeparator: \.isWhitespace)[1])
    }

    private func lines(in home: URL) throws -> [String] {
        let path = home.appendingPathComponent(".ssh/authorized_keys")
        guard let text = try? String(contentsOf: path, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }

    /// The listing is the whole answer to "what does this machine still let
    /// in?", so it has to find both kinds and leave the user's own key out of
    /// the answer — a list that included it would invite revoking it.
    @Test("listing finds both Bleat keys and ignores the user's own")
    func lists() async throws {
        let scratch = try await scratch()
        let entries = AuthorizedKeys.Entry.parse(
            output: try await scratch.shell.run(shell: AuthorizedKeys.listCommand())
        )

        #expect(entries.count == 2)
        let device = try #require(entries.first { $0.kind == .device })
        #expect(device.marker == scratch.deviceMarker)
        #expect(device.fingerprint == scratch.deviceKey.fingerprint)
        #expect(device.hasExpired() == nil)

        let enrollment = try #require(entries.first { $0.kind == .enrollment })
        #expect(enrollment.marker == scratch.enrollmentMarker)
        // Already refused by sshd. The listing says so rather than treating it
        // as an open door.
        #expect(enrollment.hasExpired() == true)
    }

    /// A machine that was never paired, and one where `~/.ssh` does not exist
    /// at all. `grep` exits 1 on no match and 2 on a missing file, and both are
    /// normal answers here — without `|| true` and `2>/dev/null` the tool would
    /// report a failure for a machine that is simply clean.
    @Test("a machine with no Bleat keys lists nothing, and does not fail")
    func listsNothing() async throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bleat-keys-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let shell = LocalShell(home: home)

        #expect(AuthorizedKeys.Entry.parse(output: try await shell.run(shell: AuthorizedKeys.listCommand())).isEmpty)

        _ = try await shell.run(shell: AuthorizedKeys.appendCommand(
            line: SSHKeyPair().authorizedKeyLine(comment: "ravil@rawillk.air")
        ))
        #expect(AuthorizedKeys.Entry.parse(output: try await shell.run(shell: AuthorizedKeys.listCommand())).isEmpty)
    }

    /// The point of the whole feature: the phone's key stops working, and
    /// nothing else in the file moves. The user's own key surviving is not a
    /// detail — a revocation that took it out would lock them out of their own
    /// machine.
    @Test("revoking a device key removes exactly that line")
    func revokesADevice() async throws {
        let scratch = try await scratch()
        _ = try await scratch.shell.run(shell: AuthorizedKeys.removeCommand(marker: scratch.deviceMarker))

        let remaining = try lines(in: scratch.home)
        #expect(remaining.count == 2)
        #expect(remaining.contains { $0.contains(blob(of: scratch.userKey)) })
        #expect(!remaining.contains { $0.contains(blob(of: scratch.deviceKey)) })

        let entries = AuthorizedKeys.Entry.parse(
            output: try await scratch.shell.run(shell: AuthorizedKeys.listCommand())
        )
        #expect(entries.map(\.kind) == [.enrollment])
    }

    /// The finding that mattered most in review, and it defeated the whole
    /// feature: a `$`-anchored pattern does not match a line ending in a space,
    /// **while sshd still accepts the key on it**. Such a key could be neither
    /// listed nor revoked. A `\r` from a file that has been through a Windows
    /// editor is the same shape.
    ///
    /// Run against real `grep` rather than against the pattern's text, because
    /// what a `$` does at the end of a line is exactly the thing that was
    /// assumed and wrong.
    @Test("a line ending in a space, or a CR, is still found and still revocable")
    func toleratesTrailingWhitespace() async throws {
        for trailer in [" ", "\t", "\r", "  \t "] {
            let home = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("bleat-keys-\(UUID().uuidString)")
            try FileManager.default.createDirectory(
                at: home.appendingPathComponent(".ssh"), withIntermediateDirectories: true
            )
            let shell = LocalShell(home: home)
            let marker = AuthorizedKeys.deviceMarker()
            let keep = SSHKeyPair().authorizedKeyLine(comment: "ravil@rawillk.air")
            try "\(keep)\n\(SSHKeyPair().authorizedKeyLine(comment: marker.value))\(trailer)\n"
                .write(to: home.appendingPathComponent(".ssh/authorized_keys"),
                       atomically: true, encoding: .utf8)

            let entries = AuthorizedKeys.Entry.parse(
                output: try await shell.run(shell: AuthorizedKeys.listCommand())
            )
            #expect(entries.map(\.marker) == [marker], "listing, trailer \(trailer.debugDescription)")

            _ = try await shell.run(shell: AuthorizedKeys.removeCommand(marker: marker))
            let remaining = try lines(in: home)
            #expect(remaining == [keep], "after revoking, trailer \(trailer.debugDescription)")
        }
    }

    /// The lock wrapper runs for reads too, and its `mkdir -p` used to leave a
    /// new `~/.ssh` at the umask default. A listing has no business creating
    /// the directory at all, and 0755 is not the mode OpenSSH creates.
    @Test("listing does not leave a world-readable ~/.ssh behind")
    func listingDoesNotCreateALooseDirectory() async throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bleat-keys-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        _ = try await LocalShell(home: home).run(shell: AuthorizedKeys.listCommand())

        let attributes = try FileManager.default.attributesOfItem(
            atPath: home.appendingPathComponent(".ssh").path
        )
        #expect(attributes[.posixPermissions] as? NSNumber == 0o700)
    }

    /// `removeCommand` exits 0 when it matches nothing, so the tool cannot use
    /// the status to decide whether anything happened. `bleat keys revoke`
    /// checks the marker is present first and asks again afterwards; this is
    /// the second of those, and it is what stops a confident "Revoked" over a
    /// file that never changed.
    @Test("the presence check answers before and after a revocation")
    func containsIsTheProof() async throws {
        let scratch = try await scratch()
        let contains = AuthorizedKeys.containsCommand(marker: scratch.deviceMarker)

        var answer = try await scratch.shell.run(shell: contains)
        #expect(answer.trimmingCharacters(in: .whitespacesAndNewlines) == "yes")

        _ = try await scratch.shell.run(shell: AuthorizedKeys.removeCommand(marker: scratch.deviceMarker))

        answer = try await scratch.shell.run(shell: contains)
        #expect(answer.trimmingCharacters(in: .whitespacesAndNewlines) == "no")
    }

    /// Two phones paired from the same machine share a marker prefix, and
    /// `removeCommand`'s pattern is anchored precisely so revoking one cannot
    /// take the other. Verified here against real `grep` rather than against
    /// the pattern's shape.
    @Test("revoking one phone leaves the other paired")
    func revokesOnlyTheNamedDevice() async throws {
        let scratch = try await scratch()
        let secondKey = SSHKeyPair()
        // Sharing a prefix with the first is the case that breaks: an
        // unanchored match for `bleat-device-01` also matches `bleat-device-012`.
        let secondMarker = try #require(
            AuthorizedKeys.deviceMarker(id: scratch.deviceMarker.value
                .replacingOccurrences(of: "bleat-device-", with: "") + "0")
        )
        _ = try await scratch.shell.run(shell: AuthorizedKeys.appendCommand(
            line: secondKey.authorizedKeyLine(comment: secondMarker.value)
        ))

        _ = try await scratch.shell.run(shell: AuthorizedKeys.removeCommand(marker: scratch.deviceMarker))

        let entries = AuthorizedKeys.Entry.parse(
            output: try await scratch.shell.run(shell: AuthorizedKeys.listCommand())
        )
        #expect(entries.contains { $0.marker == secondMarker })
        #expect(!entries.contains { $0.marker == scratch.deviceMarker })
    }
}
#endif
