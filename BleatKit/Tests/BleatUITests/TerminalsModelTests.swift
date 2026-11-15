import BleatKit
import Foundation
import Testing
@testable import BleatUI

/// A host's terminal list, and the new-terminal sheet's questions asked on
/// it, against fake cores that answer from `Fixtures/`. No network.
///
/// **Found on a phone, 14 Nov 2026,** on adam: the sheet said "Herdr's spaces
/// could not be read: the connection to herdr-core closed". It asked for the
/// host's home through `ConnectionStore.shell(for:)`, which re-dials after a
/// network change and closes the connection the list's stream rides; and the
/// list, once its stream had gone, waited for Try Again.
@Suite("A host's terminal list, and what the sheet asks on it", .serialized)
@MainActor
struct TerminalsModelTests {

    /// Plays herdr-core over one `hc connect` stream for the list.
    ///
    /// **A second fake beside `HcPaneModelTests.FakeCore`, kept from
    /// review**: the framing is alike, but the two answer different methods
    /// (attach and labels there; spaces, templates and run here), and one
    /// shared fake would mean reworking those tests for little.
    final class ListCore: DuplexStream, @unchecked Sendable {
        let output: AsyncThrowingStream<Data, any Error>
        private let feed: AsyncThrowingStream<Data, any Error>.Continuation
        private let lock = NSLock()
        private var buffer = Data()
        private var sawHello = false
        private var decoder = HcFrameDecoder()
        private var asked: [String] = []
        /// A method whose request closes the stream instead of being
        /// answered: the stream going while a request is out.
        let dropOn: String?
        /// Closes right after the snapshot: a core that goes live and drops.
        let endAfterSnapshot: Bool

        init(dropOn: String? = nil, endAfterSnapshot: Bool = false) {
            self.dropOn = dropOn
            self.endAfterSnapshot = endAfterSnapshot
            (output, feed) = AsyncThrowingStream<Data, any Error>.makeStream()
        }

        var methods: [String] { lock.withLock { asked } }

        func send(_ data: Data) async throws {
            var replies: [Data] = []
            var drop = false
            lock.withLock {
                buffer.append(data)
                if !sawHello, let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    sawHello = true
                    buffer = Data(buffer[buffer.index(after: newline)...])
                    replies.append(TerminalsModelTests.hello)
                }
                guard sawHello, let frames = try? decoder.push(buffer) else { return }
                buffer = Data()
                for frame in frames where frame.channel == 0 {
                    guard let request = try? JSONDecoder().decode(HcJSON.self, from: frame.payload),
                          let id = request["id"]?.int, let method = request["method"]?.string
                    else { continue }
                    asked.append(method)
                    if method == dropOn { drop = true; break }
                    let result: HcJSON
                    switch method {
                    case "events.subscribe":
                        var snapshot = TerminalsModelTests.fixture("hc-subscribe.json")["result"] ?? .null
                        if case .object(var fields) = snapshot { fields["channel"] = .number(2); snapshot = .object(fields) }
                        result = snapshot
                    case "doc.get": result = TerminalsModelTests.fixture("hc-doc-herdr-app.json")
                    case "templates.list": result = TerminalsModelTests.fixture("hc-templates.json")
                    case "terminal.run": result = TerminalsModelTests.fixture("hc-run.json")
                    default: continue
                    }
                    let reply = HcJSON.object(["jsonrpc": .string("2.0"), "id": .number(Double(id)), "result": result])
                    replies.append(HcFrame(channel: 0, kind: .data, payload: (try? JSONEncoder().encode(reply)) ?? Data()).encoded())
                }
            }
            replies.forEach { feed.yield($0) }
            if drop || (endAfterSnapshot && methods.contains("events.subscribe")) { end() }
        }

        /// The host closes the stream.
        func end() { feed.finish() }

        func close() async { feed.finish() }
    }

    /// A shell that records what it was asked, standing for the SSH
    /// connection under a stream.
    final class Shell: ShellRunner, @unchecked Sendable {
        private let lock = NSLock()
        private var asked: [String] = []
        var commands: [String] { lock.withLock { asked } }
        func run(shell command: String) async throws -> String {
            lock.withLock { asked.append(command) }
            return "/home/pi\n"
        }
    }

    /// `Fixtures/hc-hello.json` as the core sends it: one line.
    nonisolated static let hello: Data = {
        let reply = fixture("hc-hello.json")
        return ((try? JSONEncoder().encode(reply)) ?? Data()) + Data("\n".utf8)
    }()

    nonisolated static func fixture(_ name: String) -> HcJSON {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Fixtures/\(name)")
        return (try? JSONDecoder().decode(HcJSON.self, from: Data(contentsOf: url))) ?? .null
    }

    private let peer = PairedPeer(hostKey: "ssh-ed25519 AAAAKEY", name: "adam", username: "pi", endpoints: [])

    /// Records how many times the list opened, what each open handed out,
    /// what was handled, and how often the connection was released.
    final class Opens {
        var count = 0
        var shells: [Shell] = []
        var handled: [String] = []
        var releases = 0
    }

    /// A list over `cores`, one per open, the last repeated; each open first
    /// throws the next of `failures`, then `failure` if given, every time.
    private func list(
        _ cores: [ListCore] = [],
        failures: [any Error] = [],
        failure: (any Error)? = nil,
        retryDelays: [Duration] = [.milliseconds(20), .milliseconds(20)],
        steadyLive: Duration = .seconds(10),
        liveWait: Duration = .seconds(2)
    ) -> (TerminalsModel, Opens) {
        let opens = Opens()
        var failures = failures[...]
        var served = 0
        let model = TerminalsModel(
            peer: peer,
            open: {
                opens.count += 1
                if let next = failures.popFirst() { throw next }
                if let failure { throw failure }
                let shell = Shell()
                opens.shells.append(shell)
                defer { served += 1 }
                return .init(stream: cores[min(served, cores.count - 1)], shell: shell)
            },
            handle: { opens.handled.append(ErrorMessage.of($0)) },
            release: { opens.releases += 1 },
            retryDelays: retryDelays,
            steadyLive: steadyLive,
            liveWait: liveWait
        )
        return (model, opens)
    }

    /// Waits until `done` holds, or gives up after two seconds.
    private func eventually(_ done: () -> Bool) async {
        for _ in 0..<100 where !done() { try? await Task.sleep(for: .milliseconds(20)) }
    }

    @Test("a list whose stream closes connects again by itself, and is live")
    func reconnects() async {
        let first = ListCore(), second = ListCore()
        let (model, opens) = list([first, second])
        let running = Task { await model.run() }
        defer { running.cancel() }
        await eventually { model.phase == .live }
        first.end()
        await eventually { opens.count == 2 && model.phase == .live }
        #expect(opens.count == 2)
        #expect(model.phase == .live)
        #expect(opens.releases == 0, "a core that restarted does not cost an open terminal its connection")
    }

    /// From review: a closed stream released the shared connection every
    /// time, and an open terminal's stream went with it.
    @Test("a stream that ends quietly twice running without going live drops the connection")
    func deadConnectionReleased() async {
        let first = ListCore()
        let dead = ListCore(dropOn: "events.subscribe")
        let (model, opens) = list(
            [first, dead, dead, ListCore()],
            retryDelays: [.milliseconds(20), .milliseconds(20), .milliseconds(20)]
        )
        let running = Task { await model.run() }
        defer { running.cancel() }
        await eventually { model.phase == .live }
        first.end()
        await eventually { opens.count == 4 && model.phase == .live }
        #expect(opens.count == 4)
        #expect(opens.releases == 1, "only the second quiet end in a row, so the next open dials afresh")
    }

    @Test("a core that goes live and drops at once is not retried forever")
    func crashLoopEnds() async {
        let (model, opens) = list([ListCore(endAfterSnapshot: true)])
        await model.run()
        #expect(opens.count == 3, "the first open and both retries: going live briefly earns none back")
        guard case .failed = model.phase else { Issue.record("not failed: \(model.phase)"); return }
    }

    @Test("a list that stayed live a while earns its retries back")
    func steadyEarnsRetries() async {
        let first = ListCore(), second = ListCore()
        let (model, opens) = list([first, second, ListCore()], retryDelays: [.milliseconds(20)], steadyLive: .milliseconds(50))
        let running = Task { await model.run() }
        defer { running.cancel() }
        await eventually { model.phase == .live }
        first.end()
        await eventually { opens.count == 2 && model.phase == .live }
        try? await Task.sleep(for: .milliseconds(100))
        second.end()
        await eventually { opens.count == 3 && model.phase == .live }
        #expect(opens.count == 3)
        #expect(model.phase == .live)
    }

    /// From review: another screen's `release()` calls off the dial the
    /// list joined, and that surfaced as a failure for good.
    @Test("a dial called off under the list by another screen is retried")
    func cancelledDialRetried() async {
        let (model, opens) = list([ListCore()], failures: [CancellationError()])
        let running = Task { await model.run() }
        defer { running.cancel() }
        await eventually { model.phase == .live }
        #expect(opens.count == 2)
        #expect(model.phase == .live)
    }

    @Test("the sheet waits no longer than its limit, and says the list is still reconnecting")
    func sheetWaitIsBounded() async {
        let (model, _) = list(failure: TransportError.connectionFailed("no route"), retryDelays: [.seconds(5)], liveWait: .milliseconds(150))
        let running = Task { await model.run() }
        defer { running.cancel() }
        await eventually { model.phase == .connecting }
        let started = ContinuousClock.now
        await #expect(throws: TerminalListUnavailable.reconnecting) { try await model.spaces() }
        #expect(ContinuousClock.now - started < .seconds(1))
    }

    @Test("the sheet's shell is the list's own connection: nothing is opened or dialled for it")
    func shellIsTheList() async throws {
        let (model, opens) = list([ListCore()])
        let running = Task { await model.run() }
        defer { running.cancel() }
        await eventually { model.phase == .live }
        let shell = try await model.shell()
        _ = try await shell.run(shell: HostDirectory.home)
        #expect(opens.count == 1)
        #expect(opens.shells.first?.commands == [HostDirectory.home])
    }

    @Test("asked while the list reconnects, the spaces are read once it is live again")
    func spacesWaitForTheList() async throws {
        let first = ListCore(), second = ListCore()
        let (model, opens) = list([first, second], retryDelays: [.milliseconds(200)])
        let running = Task { await model.run() }
        defer { running.cancel() }
        await eventually { model.phase == .live }
        first.end()
        await eventually { model.phase == .connecting }
        #expect(model.phase == .connecting, "a list waiting to reconnect does not say it is live")
        let spaces = try await model.spaces()
        #expect(!spaces.isEmpty)
        #expect(opens.count == 2)
        #expect(second.methods.contains("doc.get"))
    }

    @Test("a read the stream closes under is asked again on the next stream")
    func readAskedAgain() async throws {
        let first = ListCore(dropOn: "doc.get"), second = ListCore()
        let (model, _) = list([first, second])
        let running = Task { await model.run() }
        defer { running.cancel() }
        await eventually { model.phase == .live }
        let spaces = try await model.spaces()
        #expect(!spaces.isEmpty)
        #expect(first.methods.contains("doc.get"))
        #expect(second.methods.contains("doc.get"))

        let templates = await model.templates()
        #expect(templates.map(\.name) == ["pi-env"])
    }

    @Test("a start the stream closes under is not sent again: it may have started")
    func startNotAskedAgain() async {
        let first = ListCore(dropOn: "terminal.run"), second = ListCore()
        let (model, _) = list([first, second])
        let running = Task { await model.run() }
        defer { running.cancel() }
        await eventually { model.phase == .live }
        await #expect(throws: HcProtocolError.closed) {
            try await model.start(HcRunRequest(program: .shell, name: nil, cwd: "/home/pi", size: nil, space: nil))
        }
        await eventually { model.phase == .live && !second.methods.isEmpty }
        #expect(!second.methods.contains("terminal.run"))
    }

    @Test("a core too old for Bleat is not dialled again", arguments: [
        HcProtocolError.outdated(version: "0.1.10", missing: ["terminal.attach"]) as any Error,
        TransportError.authenticationFailed("it may have been revoked there") as any Error,
        HcPaneFailure.notChecked as any Error,
    ])
    func notRetried(failure: any Error) async throws {
        let (model, opens) = list(failure: failure)
        await model.run()
        guard case .failed(let reason) = model.phase else { Issue.record("not failed: \(model.phase)"); return }
        #expect(opens.count == 1)
        await #expect(throws: TerminalListUnavailable.failed(reason), "the sheet says why, not \"closed\"") { try await model.spaces() }
    }

    @Test("an unreachable host is tried a few times, then the list fails and the sheet is not kept waiting")
    func givesUp() async {
        let (model, opens) = list(failure: TransportError.connectionFailed("no route"))
        await model.run()
        #expect(opens.count == 3, "the first dial and both retries")
        let reason = ErrorMessage.of(TransportError.connectionFailed("no route"))
        #expect(model.phase == .failed(reason))
        await #expect(throws: TerminalListUnavailable.failed(reason)) { try await model.spaces() }
    }

    @Test("in the background a lost list is not dialled again")
    func notInBackground() async {
        let first = ListCore()
        let (model, opens) = list([first, ListCore()])
        let running = Task { await model.run() }
        defer { running.cancel() }
        await eventually { model.phase == .live }
        model.inForeground = false
        first.end()
        await eventually { model.phase != .live }
        await running.value
        #expect(opens.count == 1)
        guard case .failed = model.phase else { Issue.record("not failed: \(model.phase)"); return }
    }
}
