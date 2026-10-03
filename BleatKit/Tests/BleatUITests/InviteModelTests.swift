#if canImport(UIKit)
import BleatKit
import Foundation
import Testing
@testable import BleatUI

/// Pairing another device from this one, with a host that answers the
/// `authorized_keys` commands from memory. The commands themselves are run
/// against a real shell in `InvitationShellTests`.
@Suite("Showing a pairing code for another device")
@MainActor
struct InviteModelTests {

    /// The host's file, as far as the model can see it: whether the one-time
    /// key is there, and which device keys are.
    private nonisolated final class Host: ShellRunner, @unchecked Sendable {
        private let lock = NSLock()
        private var enrollment = false
        private var devices: Set<String> = ["bleat-device-thisphone"]
        private var removals = 0

        var isEnrollmentPresent: Bool { lock.withLock { enrollment } }
        var removed: Int { lock.withLock { removals } }

        /// The other device's swap: its own key in, then the one-time key out.
        func redeem() {
            lock.withLock {
                devices.insert("bleat-device-otherphone")
                enrollment = false
            }
        }

        func run(shell command: String) async throws -> String {
            lock.withLock {
                if command == AuthorizedKeys.listDeviceMarkersCommand() {
                    return devices.sorted().joined(separator: "\n")
                }
                if command.hasPrefix("grep -q -E") { return enrollment ? "yes\n" : "no\n" }
                if command.contains("restrict,expiry-time=") {
                    enrollment = true
                } else {
                    enrollment = false
                    removals += 1
                }
                return ""
            }
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }

    private func isShowing(_ model: InviteModel) -> Bool {
        if case .showing = model.phase { true } else { false }
    }

    @Test("a code another device has used is reported as paired")
    func redeemed() async throws {
        let host = Host()
        let model = InviteModel()
        let run = Task {
            await model.run(
                peer: .preview, shell: { host }, handle: { _ in }, pollInterval: .milliseconds(10)
            )
        }
        try await waitUntil { isShowing(model) }
        #expect(host.isEnrollmentPresent)

        host.redeem()
        await run.value
        #expect(model.phase == .redeemed)
    }

    @Test("closing the screen removes the key")
    func cancelled() async throws {
        let host = Host()
        let model = InviteModel()
        let run = Task {
            await model.run(
                peer: .preview, shell: { host }, handle: { _ in }, pollInterval: .milliseconds(10)
            )
        }
        try await waitUntil { isShowing(model) }
        run.cancel()
        await run.value
        try await waitUntil { !host.isEnrollmentPresent }
        #expect(host.removed == 1)
    }

    @Test("a code nobody scanned is removed at its deadline")
    func expired() async throws {
        let host = Host()
        let model = InviteModel()
        let start = Date()
        var ticks = 0
        await model.run(
            peer: .preview, shell: { host }, handle: { _ in },
            // Opening reads the clock once; the first check after it is past
            // the deadline.
            now: {
                ticks += 1
                return ticks == 1 ? start : start.addingTimeInterval(Invitation.window + 1)
            },
            pollInterval: .milliseconds(10)
        )
        #expect(model.phase == .expired)
        #expect(!host.isEnrollmentPresent)
        #expect(host.removed == 1)
    }

    @Test("a dropped connection is handed on and the code stays up")
    func transportFailure() async throws {
        let host = Host()
        let model = InviteModel()
        var failing = false
        var handled: [any Error] = []
        let run = Task {
            await model.run(
                peer: .preview,
                shell: {
                    if failing { throw TransportError.channelClosed }
                    return host
                },
                handle: { handled.append($0) },
                pollInterval: .milliseconds(10)
            )
        }
        try await waitUntil { isShowing(model) }
        failing = true
        try await waitUntil { !handled.isEmpty }
        #expect(isShowing(model))

        failing = false
        host.redeem()
        await run.value
        #expect(model.phase == .redeemed)
    }

    @Test("a key that could not be installed is a failure, with nothing to remove")
    func failedToOpen() async {
        let model = InviteModel()
        var handled = 0
        await model.run(
            peer: .preview,
            shell: { throw TransportError.channelClosed },
            handle: { _ in handled += 1 }
        )
        guard case .failed = model.phase else {
            Issue.record("expected a failure, got \(model.phase)")
            return
        }
        #expect(handled == 1)
    }
}
#endif
