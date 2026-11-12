import Foundation
import Testing
@testable import BleatKit

/// The watch's transport against the phone's responder, joined by a function
/// call where WatchConnectivity would be. Everything that crosses is the
/// encoded bytes, so this is the wire as well as the logic.
@Suite("Reaching a host through the phone")
struct RelayTests {

    /// Stands in for the phone's SSH connection, and keeps what it was asked.
    private final class Host: PeerLink, @unchecked Sendable {
        private let lock = NSLock()
        private var log: [String] = []
        var failure: (any Error)?
        var asked: [String] { lock.withLock { log } }

        private func record(_ line: String) throws {
            lock.withLock { log.append(line) }
            if let failure { throw failure }
        }

        func run(shell command: String) async throws -> String {
            try record("shell \(command)")
            return "ran \(command)"
        }

        func disconnect() async { lock.withLock { log.append("disconnect") } }
    }

    private final class Phone: @unchecked Sendable {
        let host = Host()
        private let lock = NSLock()
        private var events: [String] = []
        var seen: [String] { lock.withLock { events } }
        var paired = [PairedPeer(
            hostKey: "ssh-ed25519 AAAAKEY", name: "Mac", username: "robin",
            endpoints: [Endpoint(string: "mac.local")!]
        )]

        private func note(_ event: String) { lock.withLock { events.append(event) } }

        var responder: RelayResponder {
            RelayResponder(
                link: { [self] hostKey in
                    guard paired.contains(where: { $0.hostKey == hostKey }) else {
                        throw RelayFailure.unknownPeer
                    }
                    return host
                },
                peers: { [self] in paired },
                release: { [self] hostKey in note("release \(hostKey)") },
                note: { [self] hostKey, change in note("note \(change)") },
                failed: { [self] error in note("failed \(error)") }
            )
        }

        func transport(for hostKey: String = "ssh-ed25519 AAAAKEY") -> RelayTransport {
            let responder = responder
            return RelayTransport(hostKey: hostKey) { await responder.reply(to: $0) }
        }
    }

    @Test("a shell command comes back as text")
    func shell() async throws {
        let phone = Phone()
        #expect(try await phone.transport().run(shell: "uname -srm") == "ran uname -srm")
        #expect(phone.host.asked == ["shell uname -srm"])
    }

    @Test("a failed shell command arrives as the ShellError it was")
    func shellError() async throws {
        let phone = Phone()
        let failure = ShellError(command: "false", exitCode: 1, stderr: "nope")
        phone.host.failure = failure
        await #expect(throws: failure) { try await phone.transport().run(shell: "false") }
    }

    @Test("a dead connection arrives as a TransportError, and the phone is told to drop it")
    func transportError() async throws {
        let phone = Phone()
        phone.host.failure = TransportError.channelClosed
        await #expect(throws: TransportError.channelClosed) {
            try await phone.transport().run(shell: "uname")
        }
        #expect(phone.seen == ["failed the connection closed"])
    }

    @Test("a host unpaired on the phone is a transport failure on the watch")
    func unknownPeer() async throws {
        let phone = Phone()
        await #expect(throws: TransportError.connectionFailed("this host is no longer paired on the iPhone")) {
            try await phone.transport(for: "ssh-ed25519 GONE").run(shell: "uname")
        }
        #expect(phone.host.asked.isEmpty)
    }

    @Test("disconnecting tells the phone to close what it opened")
    func release() async throws {
        let phone = Phone()
        await phone.transport().disconnect()
        #expect(phone.seen == ["release ssh-ed25519 AAAAKEY"])
    }

    @Test("the phone's hosts are sent whole")
    func peers() async throws {
        let phone = Phone()
        let responder = phone.responder
        let reply = try await RelayTransport.send(.peers) { await responder.reply(to: $0) }
        #expect(reply == .peers(phone.paired))
    }

    @Test("a change made on the watch reaches the phone's record")
    func note() async throws {
        let phone = Phone()
        let responder = phone.responder
        _ = try await RelayTransport.send(
            .note(hostKey: "ssh-ed25519 AAAAKEY", .hostInfo(HostInfo(system: "macOS 27.1")))
        ) { await responder.reply(to: $0) }
        #expect(phone.seen.count == 1)
        #expect(phone.seen.first?.hasPrefix("note hostInfo") == true)
    }

    @Test("a phone that cannot be asked is the channel's own error")
    func unreachable() async throws {
        let transport = RelayTransport(hostKey: "ssh-ed25519 AAAAKEY") { _ in
            throw TransportError.connectionFailed("the iPhone is out of reach")
        }
        await #expect(throws: TransportError.connectionFailed("the iPhone is out of reach")) {
            try await transport.run(shell: "uname")
        }
    }

    @Test("bytes that are not a reply are a transport failure, not contract drift")
    func garbage() async throws {
        let transport = RelayTransport(hostKey: "ssh-ed25519 AAAAKEY") { _ in Data("?".utf8) }
        // Not a `DecodingError`, which a screen reports as the host's reply
        // having drifted.
        await #expect(throws: TransportError.self) { try await transport.run(shell: "uname") }
    }

    @Test("bytes that are not a request get an answer rather than silence")
    func garbageRequest() async throws {
        let reply = await Phone().responder.reply(to: Data("?".utf8))
        guard case .failed(.other) = try JSONDecoder().decode(RelayReply.self, from: reply) else {
            Issue.record("expected a failure reply")
            return
        }
    }
}
