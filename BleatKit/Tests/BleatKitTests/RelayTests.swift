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

        func useSession(_ session: String?) { lock.withLock { log.append("use \(session ?? "-")") } }

        func run(_ args: [String]) async throws -> Data {
            try await run(args, inSession: nil)
        }

        func run(_ args: [String], inSession session: String?) async throws -> Data {
            try record("herdr[\(session ?? "-")] \(args.joined(separator: " "))")
            return Data("reply to \(args.joined(separator: " "))".utf8)
        }

        func run(shell command: String) async throws -> String {
            try record("shell \(command)")
            return "ran \(command)"
        }

        func openStream(_ args: [String]) async throws -> any HerdrStream {
            throw TransportError.notConnected
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

        func transport(for hostKey: String = "ssh-ed25519 AAAAKEY", session: String? = nil) -> RelayTransport {
            let responder = responder
            return RelayTransport(hostKey: hostKey, session: session) { await responder.reply(to: $0) }
        }
    }

    @Test("a herdr command runs on the phone's connection and its output comes back")
    func herdr() async throws {
        let phone = Phone()
        let output = try await phone.transport().run(["session", "list", "--json"])
        #expect(String(decoding: output, as: UTF8.self) == "reply to session list --json")
        #expect(phone.host.asked == ["herdr[-] session list --json"])
    }

    @Test("the session travels with each command, and the phone's own selection is left alone")
    func session() async throws {
        let phone = Phone()
        let transport = phone.transport()
        transport.useSession("scratch")
        _ = try await transport.run(["workspace", "list"])
        transport.useSession(nil)
        _ = try await transport.run(["workspace", "list"])
        _ = try await transport.run(["agent", "list"], inSession: "other")
        // No `use …` line: selecting a session on the watch never selects one
        // on the connection the phone shares between commands.
        #expect(phone.host.asked == [
            "herdr[scratch] workspace list",
            "herdr[-] workspace list",
            "herdr[other] agent list",
        ])
    }

    @Test("a shell command comes back as text")
    func shell() async throws {
        let phone = Phone()
        #expect(try await phone.transport().run(shell: "uname -srm") == "ran uname -srm")
        #expect(phone.host.asked == ["shell uname -srm"])
    }

    @Test("herdr saying no arrives as the HerdrError it was")
    func herdrError() async throws {
        let phone = Phone()
        let refusal = HerdrError(
            command: ["agent", "prompt"], exitCode: 1, stderr: "{…}",
            code: "agent_blocked", message: "the agent is waiting on an approval"
        )
        phone.host.failure = refusal
        await #expect(throws: refusal) { try await phone.transport().run(["agent", "prompt"]) }
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
            try await phone.transport().run(["agent", "list"])
        }
        #expect(phone.seen == ["failed the connection closed"])
    }

    @Test("a host unpaired on the phone is a transport failure on the watch")
    func unknownPeer() async throws {
        let phone = Phone()
        await #expect(throws: TransportError.connectionFailed("this host is no longer paired on the iPhone")) {
            try await phone.transport(for: "ssh-ed25519 GONE").run(["agent", "list"])
        }
        #expect(phone.host.asked.isEmpty)
    }

    @Test("disconnecting tells the phone to close what it opened")
    func release() async throws {
        let phone = Phone()
        await phone.transport().disconnect()
        #expect(phone.seen == ["release ssh-ed25519 AAAAKEY"])
    }

    @Test("there is no pane stream through a relay")
    func noStream() async throws {
        let phone = Phone()
        await #expect(throws: TransportError.self) {
            _ = try await phone.transport().openStream(["terminal", "session", "control"])
        }
        #expect(phone.host.asked.isEmpty)
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
            .note(hostKey: "ssh-ed25519 AAAAKEY", .startedSession("scratch"))
        ) { await responder.reply(to: $0) }
        #expect(phone.seen == [#"note startedSession("scratch")"#])
    }

    @Test("a phone that cannot be asked is the channel's own error")
    func unreachable() async throws {
        let transport = RelayTransport(hostKey: "ssh-ed25519 AAAAKEY") { _ in
            throw TransportError.connectionFailed("the iPhone is out of reach")
        }
        await #expect(throws: TransportError.connectionFailed("the iPhone is out of reach")) {
            try await transport.run(["agent", "list"])
        }
    }

    @Test("bytes that are not a reply are a transport failure, not contract drift")
    func garbage() async throws {
        let transport = RelayTransport(hostKey: "ssh-ed25519 AAAAKEY") { _ in Data("?".utf8) }
        // Not a `DecodingError`, which a screen reports as herdr having
        // changed its JSON.
        await #expect(throws: TransportError.self) { try await transport.run(["agent", "list"]) }
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
