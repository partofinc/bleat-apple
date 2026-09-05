import Crypto
import Foundation
import Testing
@testable import BleatKit

/// A host that answers the way a real one would, without being one.
///
/// It does not interpret shell. It watches for a key's base64 blob in the
/// command and decides from the verb, which is enough to test the thing that
/// matters here: the **order** of the swap, and what happens when a step does
/// not do what it said. Whether the command strings actually have that effect
/// on a real file is a different question, and it is answered against `/bin/sh`
/// in `BleatProcessTests`.
final class FakeHost: ShellRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var installed: Set<String> = []
    private var log: [String] = []

    /// What the login shell prints for `command -v herdr`.
    var herdrOutput = "/opt/homebrew/bin/herdr\n"
    /// Make the append succeed loudly and do nothing, the way `StrictModes` or
    /// a full disk would.
    var swallowAppends = false
    /// Make removal exit 0 without removing, the way a mismatched pattern would.
    var swallowRemovals = false
    /// Blobs the test wants to look for.
    var known: [String] = []

    init(alreadyInstalled: [String] = []) {
        installed = Set(alreadyInstalled)
    }

    var commands: [String] { lock.withLock { log } }

    /// A blob appears verbatim in an append and regex-escaped in a grep — the
    /// pattern escapes base64's `+`. Both forms mean "this command is about
    /// this key", so the backslashes come out before looking.
    static func mentions(_ command: String, _ blob: String) -> Bool {
        command.replacingOccurrences(of: "\\", with: "").contains(blob)
    }
    var lines: Set<String> { lock.withLock { installed } }

    func run(shell command: String) async throws -> String {
        lock.withLock { log.append(command) }
        if command == HerdrLookup.command { return herdrOutput }

        let blob = lock.withLock { known.first { Self.mentions(command, $0) } }
        guard let blob else { return "" }

        if command.contains("grep -q -E") {
            return lock.withLock { installed.contains(blob) } ? "yes\n" : "no\n"
        }
        // Order matters: `replaceKeyCommand` contains *both* verbs — it greps
        // the key out and prints it back in one command — and its net effect is
        // the insert.
        if command.contains("printf '%s\\n'") {
            if !swallowAppends { lock.withLock { installed.insert(blob) } }
            return ""
        }
        if command.contains("grep -v -E") {
            if !swallowRemovals { lock.withLock { _ = installed.remove(blob) } }
            return ""
        }
        return ""
    }
}

@Suite("Enrollment: the phone's side of the swap")
struct EnrollmentTests {

    private func blob(_ key: SSHKeyPair) -> String {
        let parsed = SSHPublicKeyLine(line: key.authorizedKeyLine(comment: ""))
        return parsed!.blob.base64EncodedString()
    }

    private func host(device: SSHKeyPair, enrollment: SSHKeyPair) -> FakeHost {
        let host = FakeHost(alreadyInstalled: [blob(enrollment)])
        host.known = [blob(device), blob(enrollment)]
        return host
    }

    @Test("the device key is installed and the enrollment key is gone")
    func happyPath() async throws {
        let device = SSHKeyPair(), enrollment = SSHKeyPair()
        let host = host(device: device, enrollment: enrollment)

        let result = try await Enrollment.redeem(
            deviceKey: device, enrollmentKey: enrollment, on: host, openDeviceSession: { host }
        )

        #expect(result.herdrPath == "/opt/homebrew/bin/herdr")
        #expect(host.lines == [blob(device)])
    }

    /// The ordering the whole design rests on. Reversed, a failure between the
    /// two leaves the phone with no credential at all: the enrollment key is
    /// gone, the device key never landed, and the only way back is to walk to
    /// the Mac.
    @Test("the device key is installed before the enrollment key is deleted")
    func installBeforeDelete() async throws {
        let device = SSHKeyPair(), enrollment = SSHKeyPair()
        let host = host(device: device, enrollment: enrollment)
        _ = try await Enrollment.redeem(
            deviceKey: device, enrollmentKey: enrollment, on: host, openDeviceSession: { host }
        )

        let deviceBlob = blob(device), enrollmentBlob = blob(enrollment)
        let installed = try #require(host.commands.firstIndex {
            $0.contains("printf '%s\\n'") && FakeHost.mentions($0, deviceBlob)
        })
        let deleted = try #require(host.commands.firstIndex {
            $0.contains("grep -v -E") && FakeHost.mentions($0, enrollmentBlob)
        })
        #expect(installed < deleted)
    }

    /// The same failure one step later: the append reported success and did
    /// nothing. Deleting anyway would strand the phone; leaving the enrollment
    /// key alone means the user can simply scan again.
    @Test("an install that silently did nothing leaves the enrollment key alone")
    func doesNotDeleteWhenInstallFailed() async throws {
        let device = SSHKeyPair(), enrollment = SSHKeyPair()
        let host = host(device: device, enrollment: enrollment)
        host.swallowAppends = true

        await #expect(throws: PairingError.self) {
            try await Enrollment.redeem(
                deviceKey: device, enrollmentKey: enrollment, on: host, openDeviceSession: { host }
            )
        }
        #expect(host.lines == [blob(enrollment)])
        #expect(!host.commands.contains { $0.contains("grep -v -E") && FakeHost.mentions($0, blob(enrollment)) })
    }

    /// `bleat pair` waits for the enrollment line to disappear before it calls
    /// the pairing done. A removal that exits 0 without removing would hang the
    /// tool until its window closed while the phone claimed success — and leave
    /// a working key on the host until `expiry-time` caught it.
    @Test("a removal that did not remove is reported, not assumed")
    func verifiesRemoval() async throws {
        let device = SSHKeyPair(), enrollment = SSHKeyPair()
        let host = host(device: device, enrollment: enrollment)
        host.swallowRemovals = true

        await #expect(throws: PairingError.self) {
            try await Enrollment.redeem(
                deviceKey: device, enrollmentKey: enrollment, on: host, openDeviceSession: { host }
            )
        }
    }

    /// Resolved before anything is written, so a host that cannot serve the app
    /// leaves nothing to undo.
    @Test("a host without herdr is refused before authorized_keys is touched")
    func herdrMissing() async throws {
        let device = SSHKeyPair(), enrollment = SSHKeyPair()
        let host = host(device: device, enrollment: enrollment)
        host.herdrOutput = "\n"

        await #expect(throws: PairingError.herdrNotFound) {
            try await Enrollment.redeem(
                deviceKey: device, enrollmentKey: enrollment, on: host, openDeviceSession: { host }
            )
        }
        #expect(host.commands.count == 1)
        #expect(host.lines == [blob(enrollment)])
    }

    /// The host judges redemption by a **new** `bleat-device-` marker
    /// appearing. A device line whose comment did not match that pattern would
    /// pair the phone perfectly and time the tool out anyway.
    @Test("the device line carries a marker the host's own grep will find")
    func markerMatchesTheHostsPattern() async throws {
        let device = SSHKeyPair(), enrollment = SSHKeyPair()
        let host = host(device: device, enrollment: enrollment)
        let result = try await Enrollment.redeem(
            deviceKey: device, enrollmentKey: enrollment, on: host, openDeviceSession: { host }
        )

        let appended = try #require(host.commands.first { $0.contains("printf '%s\\n'") })
        #expect(appended.contains(result.deviceMarker))
        #expect(result.deviceMarker.hasPrefix("bleat-device-"))
        // The pattern `listDeviceMarkersCommand` greps with, applied here.
        let pattern = try Regex("[[:space:]]bleat-device-[A-Za-z0-9._-]+$")
        let line = device.authorizedKeyLine(comment: result.deviceMarker)
        #expect(line.firstMatch(of: pattern) != nil)
    }

    /// Re-pairing a phone that is already known must not append a second copy
    /// of the same key — and must not have a moment where the key is absent
    /// either. For an already-paired phone that moment holds its only durable
    /// credential, so removal and insertion are one command.
    @Test("re-pairing replaces this device's line without ever removing it alone")
    func rePairingReplacesAtomically() async throws {
        let device = SSHKeyPair(), enrollment = SSHKeyPair()
        let host = host(device: device, enrollment: enrollment)
        _ = try await Enrollment.redeem(
            deviceKey: device, enrollmentKey: enrollment, on: host, openDeviceSession: { host }
        )

        let deviceBlob = blob(device)
        let touching = host.commands.filter { FakeHost.mentions($0, deviceBlob) }
        // One command that both clears and writes, plus the read that verifies
        // it. Never a removal standing on its own.
        let install = try #require(touching.first { $0.contains("printf '%s\\n'") })
        #expect(install.contains("grep -v -E"))
        #expect(!touching.contains { $0.contains("grep -v -E") && !$0.contains("printf '%s\\n'") })
    }

    /// The check a file cannot make. A line in `authorized_keys` is not the
    /// same claim as "sshd will accept this key": `StrictModes` ignores a file
    /// whose permissions drifted, and `AuthorizedKeysFile` can point somewhere
    /// other than `~/.ssh` entirely. Both leave a file that reads back
    /// perfectly and a phone that cannot connect.
    ///
    /// Found the hard way, in a live run: an sshd configured to read keys from
    /// somewhere other than the session's own `~` accepted every step and
    /// reported a successful pairing that could never have worked.
    @Test("a host that will not accept the new key keeps the enrollment key")
    func requiresTheHostToAcceptTheNewKey() async throws {
        struct Refused: Error {}
        let device = SSHKeyPair(), enrollment = SSHKeyPair()
        let host = host(device: device, enrollment: enrollment)

        await #expect(throws: PairingError.self) {
            try await Enrollment.redeem(
                deviceKey: device,
                enrollmentKey: enrollment,
                on: host,
                openDeviceSession: { throw Refused() }
            )
        }
        // Still installed, so the user can scan again rather than walk to the
        // Mac — and still the enrollment key's own line, so `bleat pair` can
        // remove it when its window closes.
        #expect(host.lines.contains(blob(enrollment)))
        #expect(!host.commands.contains { $0.contains("grep -v -E") && FakeHost.mentions($0, blob(enrollment)) })
    }
}

@Suite("Finding herdr on the host")
struct HerdrLookupTests {

    /// A login shell sources the profile, and profiles print things. Taking the
    /// whole of stdout would store the banner as part of the path.
    @Test("the answer is the last line, not the whole of a chatty profile")
    func ignoresProfileNoise() {
        let output = """
        Welcome back!
        nvm: using node 20
        /opt/homebrew/bin/herdr
        """
        #expect(HerdrLookup.path(inOutput: output) == "/opt/homebrew/bin/herdr")
    }

    @Test("a trailing newline does not become the answer")
    func trailingNewline() {
        #expect(HerdrLookup.path(inOutput: "/usr/local/bin/herdr\n") == "/usr/local/bin/herdr")
    }

    /// `command -v` also answers with builtins and functions by bare name, and
    /// a relative answer is not something a later non-login shell can resolve.
    @Test("only an absolute path counts as found")
    func rejectsRelative() {
        #expect(HerdrLookup.path(inOutput: "herdr\n") == nil)
        #expect(HerdrLookup.path(inOutput: "") == nil)
        #expect(HerdrLookup.path(inOutput: "\n \n") == nil)
    }
}
