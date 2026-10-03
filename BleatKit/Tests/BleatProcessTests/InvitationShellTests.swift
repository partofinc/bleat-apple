#if os(macOS)
import BleatKit
import Foundation
import Testing

/// Pairing another device from a paired one, against a real shell and a real
/// `authorized_keys` — the inviting side and the redeeming side both.
@Suite("Inviting a device, against a real shell")
struct InvitationShellTests {

    /// A key the user put there, which nothing here may touch.
    private let usersKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMhKfcrGJN9TJkeFBij/SoJie+EkZFSkE0zVCLVZbsnj ravil@laptop"

    private let peer = PairedPeer(
        hostKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG5cjZ26Q+4UUiEfZnfwG+hUvC3MasbyQN8yihaMCcTY",
        name: "adam",
        username: "pi",
        endpoints: [Endpoint(host: "adam.local"), Endpoint(host: "100.101.102.103", port: 2222)]
    )

    /// A home with a `herdr` on the login shell's `PATH`, so the redeeming
    /// side's lookup succeeds, and the user's own key already installed.
    private func scratchHome() async throws -> (URL, LocalShell) {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bleat-invite-\(UUID().uuidString)")
        let bin = home.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let herdr = bin.appendingPathComponent("herdr")
        try "#!/bin/sh\necho stub\n".write(to: herdr, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: herdr.path)
        try "PATH=\(bin.path):$PATH\n"
            .write(to: home.appendingPathComponent(".profile"), atomically: true, encoding: .utf8)
        let shell = LocalShell(home: home)
        _ = try await shell.run(shell: AuthorizedKeys.appendCommand(line: usersKey))
        return (home, shell)
    }

    private func lines(in home: URL) -> [String] {
        let path = home.appendingPathComponent(".ssh/authorized_keys")
        guard let text = try? String(contentsOf: path, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }

    @Test("the code carries what the host's own tool would, and the key behind it is live")
    func open() async throws {
        let (home, shell) = try await scratchHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let now = Date()

        let invitation = try await Invitation.open(for: peer, on: shell, now: now)

        let scanned = try PairingPayload(urlString: invitation.link())
        #expect(scanned.hostKey == peer.hostKey)
        #expect(scanned.username == "pi")
        #expect(scanned.name == "adam")
        #expect(scanned.endpoints == peer.endpoints)
        #expect(invitation.deadline == now.addingTimeInterval(Invitation.window))

        let enrollment = try #require(lines(in: home).first { $0.contains(invitation.marker.value) })
        // sshd's two guards, as `bleat pair` writes them.
        #expect(enrollment.hasPrefix("restrict,expiry-time="))
        #expect(enrollment.contains(try scanned.enrollmentKey().authorizedKeyLine(comment: "")))
        #expect(lines(in: home).contains(usersKey))
        #expect(try await invitation.state(on: shell) == .waiting)
    }

    /// The other device runs the same swap it runs against `bleat pair`'s
    /// code; the inviting side has to see it as done.
    @Test("a redemption is seen as one")
    func redeemed() async throws {
        let (home, shell) = try await scratchHome()
        defer { try? FileManager.default.removeItem(at: home) }
        // A device already paired — this one — so "a device key exists" is
        // true from the start and cannot be what decides.
        _ = try await shell.run(shell: AuthorizedKeys.appendCommand(
            line: SSHKeyPair().authorizedKeyLine(comment: AuthorizedKeys.deviceMarker().value)
        ))

        let invitation = try await Invitation.open(for: peer, on: shell)
        let scanned = try PairingPayload(urlString: invitation.link())
        let redemption = try await Enrollment.redeem(
            deviceKey: SSHKeyPair(), enrollmentKey: try scanned.enrollmentKey(),
            on: shell, openDeviceSession: { shell }
        )

        #expect(try await invitation.state(on: shell) == .redeemed)
        #expect(lines(in: home).contains { $0.hasSuffix(redemption.deviceMarker) })
        #expect(lines(in: home).contains(usersKey))
        #expect(lines(in: home).count == 3)
    }

    @Test("withdrawing removes the key and nothing else, and may be repeated")
    func withdraw() async throws {
        let (home, shell) = try await scratchHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let invitation = try await Invitation.open(for: peer, on: shell)
        try await invitation.withdraw(on: shell)
        try await invitation.withdraw(on: shell)

        #expect(lines(in: home) == [usersKey])
        #expect(try await invitation.state(on: shell) == .withdrawn)
    }

    /// `bleat pair` sweeps every enrollment key before minting its own, so
    /// running it at the host ends a code shown on a phone. The phone has to
    /// say so rather than wait out the window.
    @Test("a key swept at the host is reported as withdrawn, not as used")
    func sweptAtTheHost() async throws {
        let (home, shell) = try await scratchHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let invitation = try await Invitation.open(for: peer, on: shell)
        _ = try await shell.run(shell: AuthorizedKeys.sweepEnrollmentsCommand())

        #expect(try await invitation.state(on: shell) == .withdrawn)
    }

    /// Another pairing may be in progress — at the host's keyboard, or from a
    /// second phone. Opening one must not end it.
    @Test("opening a code leaves another enrollment key alone")
    func leavesOthersAlone() async throws {
        let (home, shell) = try await scratchHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let first = try await Invitation.open(for: peer, on: shell)
        let second = try await Invitation.open(for: peer, on: shell)
        #expect(try await first.state(on: shell) == .waiting)

        try await second.withdraw(on: shell)
        #expect(try await first.state(on: shell) == .waiting)
        #expect(lines(in: home).count == 2)
    }
}
#endif
