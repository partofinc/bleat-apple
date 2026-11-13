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

        /// A core that never answers, as one over a silently dead session.
        var hangs = false
        /// What the last call was made with, after the phone's checks.
        private var lastParams: [String: HcJSON] = [:]
        var params: [String: HcJSON] { lock.withLock { lastParams } }

        /// herdr-core on this host: answers from `Fixtures/`.
        func hc(_ method: String, _ params: [String: HcJSON]) async throws -> HcJSON {
            try record("hc \(method) \(params["terminal"]?.string ?? "")")
            lock.withLock { lastParams = params }
            if hangs { try await Task.sleep(for: .seconds(3600)) }
            switch method {
            case "terminal.list":
                return try JSONDecoder().decode(HcJSON.self, from: Fixture.data("hc-terminal-list.json"))["result"] ?? .null
            case "terminal.read":
                return try JSONDecoder().decode(HcJSON.self, from: Fixture.data("hc-terminal-read.json"))["result"] ?? .null
            default:
                return .object([:])
            }
        }
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
                hc: { [self] hostKey, method, params in
                    guard paired.contains(where: { $0.hostKey == hostKey }) else {
                        throw RelayFailure.unknownPeer
                    }
                    return try await host.hc(method, params)
                },
                failed: { [self] error in note("failed \(error)") }
            )
        }

        var hcDeadline = Duration.seconds(8)

        func transport(for hostKey: String = "ssh-ed25519 AAAAKEY") -> RelayTransport {
            var configured = responder
            configured.hcDeadline = hcDeadline
            let responder = configured
            return RelayTransport(hostKey: hostKey) { await responder.reply(to: $0) }
        }
    }

    // MARK: - herdr-core

    @Test("a herdr-core call comes back as its result, and the list reads from it")
    func hcCall() async throws {
        let phone = Phone()
        var set = HcTerminalSet()
        set.reset(to: try await phone.transport().call("terminal.list"))
        #expect(set.listed.map(\.address) == ["t5s", "t6g"])
        #expect(set.listed.first?.isUnseenDone == true)
        #expect(phone.host.asked == ["hc terminal.list "])
    }

    @Test("a terminal's screen comes back as text")
    func hcRead() async throws {
        let phone = Phone()
        let screen = try HcScreenText(reply: try await phone.transport().call("terminal.read", ["terminal": .string("t6g"), "lines": .number(0)]))
        #expect(screen.lastLines(2) == ["hello from scratch", "sh-3.2$"])
    }

    @Test("herdr-core refusing arrives as the HcError it was")
    func hcError() async throws {
        let phone = Phone()
        let refusal = HcError(code: -32000, message: "no terminal t9", kind: "not_found")
        phone.host.failure = refusal
        await #expect(throws: refusal) { try await phone.transport().call("terminal.get", ["terminal": .string("t9")]) }
    }

    /// The watch reads and marks what it read; nothing it sends starts, types
    /// into or ends anything.
    @Test("a call outside what the watch may make is refused before the host", arguments: [
        "terminal.run", "terminal.send", "terminal.keys", "terminal.kill", "terminal.rm", "doc.set", "server.stop",
    ])
    func hcRefused(method: String) async throws {
        let phone = Phone()
        await #expect(throws: RelayFailure.refused("the watch may not call \(method)")) {
            try await phone.transport().call(method)
        }
        #expect(phone.host.asked.isEmpty)
    }

    /// From review: the method alone let any label through, which could take
    /// a terminal out of its Herdr.app space or clear the Mac's "done".
    @Test("a label call carries herdr.seen and a turn number, and nothing else", arguments: [
        ["terminal": HcJSON.string("t5"), "labels": .object(["herdr.space": .string("")])],
        ["terminal": .string("t5"), "labels": .object(["herdr.seen": .string("3"), "where": .string("x")])],
        ["terminal": .string("t5"), "labels": .object(["herdr.seen": .string("-1")])],
        ["terminal": .string("t5"), "labels": .object(["herdr.seen": .string("")])],
        ["labels": .object(["herdr.seen": .string("3")])],
        ["terminal": .string("t5"), "labels": .object(["herdr.seen": .string("3")]), "caller": .string("t1")],
    ])
    func labelRefused(params: [String: HcJSON]) async throws {
        let phone = Phone()
        await #expect(throws: RelayFailure.refused("the watch may not call terminal.label like that")) {
            try await phone.transport().call("terminal.label", params)
        }
        #expect(phone.host.asked.isEmpty)
    }

    @Test("a seen write goes through as it was sent")
    func labelAllowed() async throws {
        let phone = Phone()
        _ = try await phone.transport().call("terminal.label", HcSeen.params(address: "t5", turn: 12))
        #expect(phone.host.params == HcSeen.params(address: "t5", turn: 12))
    }

    @Test("a read asks for at most a bounded history, and a list for nothing")
    func readBounded() async throws {
        let phone = Phone()
        _ = try await phone.transport().call("terminal.read", ["terminal": .string("t5"), "lines": .number(1_000_000)])
        #expect(phone.host.params["lines"] == .number(Double(RelayRequest.maxReadLines)))
        await #expect(throws: RelayFailure.refused("the watch may not call terminal.list like that")) {
            try await phone.transport().call("terminal.list", ["all": .bool(true)])
        }
    }

    /// From review: as `.other` these became `TransportError`, and every poll
    /// dropped and re-dialled the SSH connection.
    @Test("herdr-core's protocol failures and the phone's refusals do not drop the connection")
    func notFatal() async throws {
        let phone = Phone()
        phone.host.failure = HcProtocolError.unsupportedGeneration(2)
        await #expect(throws: HcProtocolError.unsupportedGeneration(2)) { try await phone.transport().call("terminal.list") }
        #expect(!ConnectionPolicy.isFatalToConnection(HcProtocolError.unsupportedGeneration(2)))
        #expect(!ConnectionPolicy.isFatalToConnection(RelayFailure.refused("no").error))
    }

    /// From review: a call over a session that died without a word never
    /// returned, and the phone stayed awake and connected.
    @Test("a core that never answers is a transport failure at the deadline")
    func deadline() async throws {
        let phone = Phone()
        phone.host.hangs = true
        phone.hcDeadline = .milliseconds(100)
        let started = ContinuousClock.now
        await #expect(throws: TransportError.self) { try await phone.transport().call("terminal.list") }
        #expect(ContinuousClock.now - started < .seconds(5))
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
