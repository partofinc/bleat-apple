import Foundation
import Testing
@testable import BleatKit

@Suite("Taking this device's key back off a host")
struct RevocationTests {

    private func blob(of key: SSHKeyPair) -> String {
        String(key.authorizedKeyLine(comment: "").split(whereSeparator: \.isWhitespace)[1])
    }

    @Test("the device key is removed and the removal is proved")
    func revokes() async throws {
        let device = SSHKeyPair()
        let host = FakeHost(alreadyInstalled: [blob(of: device)])
        host.known = [blob(of: device)]

        try await Revocation.revokeDeviceKey(device, on: host)

        #expect(host.lines.isEmpty)
        // The proof is not optional. Removing and trusting it is the same
        // mistake `Enrollment` refuses to make one step earlier.
        #expect(host.commands.contains { $0.contains("grep -q -E") })
    }

    /// `removeKeyCommand` ends in `|| true`, so a removal that matched nothing
    /// exits 0 exactly like one that worked. Reporting that as success would
    /// tell the user a key is gone while it still opens a shell — the precise
    /// lie the whole feature exists to stop.
    @Test("a removal that quietly did nothing is a failure, not a success")
    func silentFailureIsReported() async throws {
        let device = SSHKeyPair()
        let host = FakeHost(alreadyInstalled: [blob(of: device)])
        host.known = [blob(of: device)]
        host.swallowRemovals = true

        await #expect(throws: PairingError.self) {
            try await Revocation.revokeDeviceKey(device, on: host)
        }
        #expect(host.lines.contains(blob(of: device)), "the key really is still there")
    }

    /// **The finding this test used to hide.** It asserted that a host with no
    /// such key revokes "successfully", which locked in exactly the wrong
    /// behaviour — the same shape as the `Agent.target` test that passed while
    /// the property was wrong.
    ///
    /// The connection was authenticated *with this key*, so sshd accepts it
    /// from somewhere. Not finding it in `authorized_keys` means sshd is
    /// reading a different file, and nothing done to this one revokes
    /// anything. Reporting success there deletes the peer record and leaves the
    /// phone a full shell with nothing naming the line.
    @Test("a key sshd accepts but that is not in the file is a failure")
    func absentFromTheFileIsAFailure() async {
        let device = SSHKeyPair()
        let host = FakeHost()
        host.known = [blob(of: device)]

        await #expect(throws: PairingError.self) {
            try await Revocation.revokeDeviceKey(device, on: host)
        }
    }

    /// The phone holds one key for every host it has paired with, so the
    /// command must name *this* key rather than "the Bleat key". A pattern that
    /// matched by marker prefix would take a second phone's line on a machine
    /// two phones are paired to.
    @Test("only this device's key is named, not every Bleat key")
    func namesOnlyThisKey() async throws {
        let device = SSHKeyPair()
        let other = SSHKeyPair()
        let host = FakeHost(alreadyInstalled: [blob(of: device), blob(of: other)])
        host.known = [blob(of: device), blob(of: other)]

        try await Revocation.revokeDeviceKey(device, on: host)

        #expect(host.lines == [blob(of: other)])
    }

    /// A transport failure must not read as "revoked". `FakeHost` throws
    /// nothing on its own, so this drives the failure through a runner that
    /// only throws — the shape of a connection that dropped mid-command.
    @Test("a failed command is not mistaken for a removal")
    func brokenConnection() async {
        struct Broken: ShellRunner {
            func run(shell command: String) async throws -> String {
                throw ShellError(command: command, exitCode: 255, stderr: "connection closed")
            }
        }
        await #expect(throws: ShellError.self) {
            try await Revocation.revokeDeviceKey(SSHKeyPair(), on: Broken())
        }
    }
}
