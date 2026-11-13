import BleatKit
import Foundation
import Testing
@testable import BleatUI

/// The hc terminal screen's model, against a fake core that answers the way
/// hc 0.1.20 did live: `hello` as a line, then `terminal.attach` on channel 0
/// and a first paint on channel 1. No network.
@Suite("A herdr-core terminal's screen")
@MainActor
struct HcPaneModelTests {

    /// Plays herdr-core over one `hc connect` stream, and records what the
    /// client sent.
    final class FakeCore: DuplexStream, @unchecked Sendable {
        let output: AsyncThrowingStream<Data, any Error>
        private let feed: AsyncThrowingStream<Data, any Error>.Continuation
        private let lock = NSLock()
        private var buffer = Data()
        private var sawHello = false
        private var decoder = HcFrameDecoder()
        private(set) var sent: [HcFrame] = []
        private(set) var closed = false
        let paint = Data("first paint\r\n$ ".utf8)

        init() { (output, feed) = AsyncThrowingStream<Data, any Error>.makeStream() }

        func send(_ data: Data) async throws {
            var replies: [Data] = []
            lock.withLock {
                buffer.append(data)
                if !sawHello, let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    sawHello = true
                    buffer = Data(buffer[buffer.index(after: newline)...])
                    replies.append(Data(#"{"jsonrpc":"2.0","id":0,"result":{"framed":true,"generation":1,"version":"0.1.20"}}"#.utf8) + Data("\n".utf8))
                }
                guard sawHello, let frames = try? decoder.push(buffer) else { return }
                buffer = Data()
                for frame in frames {
                    sent.append(frame)
                    guard frame.channel == 0,
                          let request = try? JSONDecoder().decode(HcJSON.self, from: frame.payload),
                          request["method"]?.string == "terminal.attach",
                          let id = request["id"]?.int
                    else { continue }
                    let reply = #"{"jsonrpc":"2.0","id":\#(id),"result":{"channel":1,"terminal":{"address":"t5n","state":"live"}}}"#
                    replies.append(HcFrame(channel: 0, kind: .data, payload: Data(reply.utf8)).encoded())
                    replies.append(HcFrame(channel: 1, kind: .data, payload: paint).encoded())
                }
            }
            replies.forEach { feed.yield($0) }
        }

        func close() async {
            lock.withLock { closed = true }
            feed.finish()
        }

        /// The core closes the screen's channel: the program ended.
        func endProgram() { feed.yield(HcFrame(channel: 1, kind: .close).encoded()) }

        var attachRequest: HcJSON? {
            lock.withLock {
                sent.lazy.compactMap { try? JSONDecoder().decode(HcJSON.self, from: $0.payload) }
                    .first { $0["method"]?.string == "terminal.attach" }
            }
        }

        /// What went out on the screen's channel, in order, credit left out.
        var input: [HcFrame] {
            lock.withLock { sent.filter { $0.channel == 1 && $0.knownKind != .credit } }
        }

        var isClosed: Bool { lock.withLock { closed } }
    }

    private func model(_ cores: [FakeCore]) -> (HcPaneModel, () -> Int) {
        var opened = 0
        let model = HcPaneModel(
            address: "t5n",
            open: {
                defer { opened += 1 }
                return cores[min(opened, cores.count - 1)]
            },
            report: { _ in }
        )
        return (model, { opened })
    }

    /// Waits until `done` holds, or gives up after two seconds.
    private func eventually(_ done: () -> Bool) async {
        for _ in 0..<100 where !done() { try? await Task.sleep(for: .milliseconds(20)) }
    }

    @Test("it attaches at the terminal's measured grid, with history, and paints")
    func attaches() async throws {
        let core = FakeCore()
        let (model, _) = model([core])
        var painted = Data()
        model.show(TerminalGrid(cols: 53, rows: 30))
        await eventually { model.phase == .live }
        // The renderer can arrive before or after the first paint: held for
        // it in one case, handed straight over in the other. Either way it
        // gets the paint, once — the phase turns live as the attach lands,
        // which can be a moment before the paint does.
        model.attach { painted.append($0) }
        #expect(model.phase == .live)
        await eventually { painted == core.paint }
        #expect(painted == core.paint)
        let request = try #require(core.attachRequest)
        #expect(request["params"]?["cols"]?.int == 53)
        #expect(request["params"]?["rows"]?.int == 30)
        #expect(request["params"]?["history"]?.int == HcPaneModel.history)
        #expect(request["params"]?["terminal"]?.string == "t5n")
        await model.close()
    }

    /// A rotation sent on its own could reach the core before keys typed
    /// before it.
    @Test("keys and a resize go out in the order they happened")
    func ordering() async throws {
        let core = FakeCore()
        let (model, _) = model([core])
        model.show(TerminalGrid(cols: 53, rows: 30))
        await eventually { model.phase == .live }
        await model.send(bytes: Data("a".utf8))
        model.show(TerminalGrid(cols: 90, rows: 20))
        await eventually { model.grid == TerminalGrid(cols: 90, rows: 20) }
        await model.send(bytes: Data("b".utf8))
        await eventually { core.input.count == 3 }
        let input = core.input
        #expect(input.map(\.knownKind) == [.data, .resize, .data])
        #expect(input.first?.payload == Data("a".utf8))
        #expect(Array(input[1].payload) == [90, 0, 20, 0])
        await model.close()
    }

    @Test("a composed line is its text, then Enter")
    func submit() async throws {
        let core = FakeCore()
        let (model, _) = model([core])
        model.show(TerminalGrid(cols: 53, rows: 30))
        await eventually { model.phase == .live }
        await model.submit(try #require(SubmittedLine("ls -la")))
        await eventually { core.input.count == 2 }
        #expect(core.input.map(\.payload) == [Data("ls -la".utf8), TerminalKey.enter.bytes])
        await model.close()
    }

    @Test("several lines go as one paste where the program takes one, and as one line where not")
    func submitLines() async throws {
        let core = FakeCore()
        let (model, _) = model([core])
        var paste = true
        model.attachPasteMode { paste }
        model.show(TerminalGrid(cols: 53, rows: 30))
        await eventually { model.phase == .live }
        let prompt = try #require(SubmittedLine("look at this\nthen fix it"))
        await model.submit(prompt)
        await eventually { core.input.count == 2 }
        #expect(core.input.map(\.payload) == [
            Data("\u{1B}[200~look at this\nthen fix it\u{1B}[201~".utf8), TerminalKey.enter.bytes,
        ])

        paste = false
        await model.submit(prompt)
        await eventually { core.input.count == 4 }
        #expect(core.input.suffix(2).map(\.payload) == [Data("look at this then fix it".utf8), TerminalKey.enter.bytes])
        await model.close()
    }

    /// The `hc connect` stayed open, and keys went into a dead channel.
    @Test("when the program ends, the screen ends and its connection closes")
    func programEnds() async {
        let core = FakeCore()
        let (model, _) = model([core])
        model.show(TerminalGrid(cols: 53, rows: 30))
        await eventually { model.phase == .live }
        core.endProgram()
        await eventually { model.phase == .ended }
        #expect(model.phase == .ended)
        await eventually { core.isClosed }
        #expect(core.isClosed)
        await model.send(bytes: Data("x".utf8))
        #expect(core.input.isEmpty, "nothing goes into an ended terminal")
    }

    /// A covering sheet or an iPad column change; closing for good left a
    /// frozen screen that still said it was live.
    @Test("off screen lets go, and back on screen attaches again")
    func leavesAndComesBack() async {
        let first = FakeCore()
        let second = FakeCore()
        let (model, opened) = model([first, second])
        model.show(TerminalGrid(cols: 53, rows: 30))
        await eventually { model.phase == .live }
        model.setActive(false)
        #expect(model.phase == .opening)
        await eventually { first.isClosed }
        #expect(first.isClosed, "the viewer left, so the Mac has its size back")
        model.setActive(true)
        await eventually { model.phase == .live && opened() == 2 }
        #expect(opened() == 2)
        #expect(second.attachRequest != nil)
        await model.close()
    }

    @Test("a closed screen never attaches again")
    func closedStaysClosed() async {
        let core = FakeCore()
        let (model, opened) = model([core])
        model.show(TerminalGrid(cols: 53, rows: 30))
        await eventually { model.phase == .live }
        await model.close()
        model.retry()
        model.show(TerminalGrid(cols: 60, rows: 30))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(opened() == 1)
    }
}
