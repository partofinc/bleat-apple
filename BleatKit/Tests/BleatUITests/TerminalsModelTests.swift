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

        init(dropOn: String? = nil) {
            self.dropOn = dropOn
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
                    replies.append(Data(#"{"jsonrpc":"2.0","id":0,"result":{"framed":true,"generation":1,"version":"0.1.20"}}"#.utf8) + Data("\n".utf8))
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
            if drop { end() }
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

    nonisolated static func fixture(_ name: String) -> HcJSON {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Fixtures/\(name)")
        return (try? JSONDecoder().decode(HcJSON.self, from: Data(contentsOf: url))) ?? .null
    }

    private let peer = PairedPeer(hostKey: "ssh-ed25519 AAAAKEY", name: "adam", username: "pi", endpoints: [])

    /// Records how many times the list opened, what each open handed out,
    /// and what was reported.
    final class Opens {
        var count = 0
        var shells: [Shell] = []
        var reported: [String] = []
    }

    /// A list over `cores`, one per open, the last repeated; or failing with
    /// `failure` on every open.
    private func list(
        _ cores: [ListCore] = [],
        failure: (any Error)? = nil,
        retryDelays: [Duration] = [.milliseconds(20), .milliseconds(20)],
        liveWait: Duration = .seconds(2)
    ) -> (TerminalsModel, Opens) {
        let opens = Opens()
        let model = TerminalsModel(
            peer: peer,
            open: {
                defer { opens.count += 1 }
                if let failure { throw failure }
                let shell = Shell()
                opens.shells.append(shell)
                return .init(stream: cores[min(opens.count, cores.count - 1)], shell: shell)
            },
            report: { opens.reported.append(ErrorMessage.of($0)) },
            retryDelays: retryDelays,
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
        #expect(opens.reported.count == 1, "the closed stream was reported, so the connection is dropped and dialled again")
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
        guard case .failed = model.phase else { Issue.record("not failed: \(model.phase)"); return }
        #expect(opens.count == 1)
        await #expect(throws: HcProtocolError.closed) { try await model.spaces() }
    }

    @Test("an unreachable host is tried a few times, then the list fails and the sheet is not kept waiting")
    func givesUp() async {
        let (model, opens) = list(failure: TransportError.connectionFailed("no route"))
        await model.run()
        #expect(opens.count == 3, "the first dial and both retries")
        #expect(model.phase == .failed(ErrorMessage.of(TransportError.connectionFailed("no route"))))
        await #expect(throws: HcProtocolError.closed) { try await model.spaces() }
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
