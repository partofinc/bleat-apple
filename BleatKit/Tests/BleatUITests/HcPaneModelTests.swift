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
        /// The subscription's snapshot: `Fixtures/hc-turn-events.ndjson`'s,
        /// a scratch Claude Code at turn 0 with no labels (captured live).
        var snapshot: HcJSON = HcPaneModelTests.turnFixture.snapshot
        /// `herdr.seen` values the client asked `terminal.label` to set.
        private(set) var seenWrites: [String] = []
        /// How many `terminal.label` calls to refuse before answering.
        var labelFailures = 0

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
                          let id = request["id"]?.int
                    else { continue }
                    switch request["method"]?.string {
                    case "events.subscribe":
                        // The captured reply, on a channel of its own as a
                        // framed core gives one.
                        var result = snapshot
                        if case .object(var fields) = result { fields["channel"] = .number(2); result = .object(fields) }
                        let reply = HcJSON.object(["jsonrpc": .string("2.0"), "id": .number(Double(id)), "result": result])
                        replies.append(HcFrame(channel: 0, kind: .data, payload: (try? JSONEncoder().encode(reply)) ?? Data()).encoded())
                        continue
                    case "terminal.label":
                        let reply: String
                        if labelFailures > 0 {
                            labelFailures -= 1
                            reply = #"{"jsonrpc":"2.0","id":\#(id),"error":{"code":-32000,"message":"unavailable","data":{"kind":"unavailable"}}}"#
                        } else {
                            if let value = request["params"]?["labels"]?["herdr.seen"]?.string { seenWrites.append(value) }
                            reply = #"{"jsonrpc":"2.0","id":\#(id),"result":{}}"#
                        }
                        replies.append(HcFrame(channel: 0, kind: .data, payload: Data(reply.utf8)).encoded())
                        continue
                    case "terminal.attach":
                        break
                    default:
                        continue
                    }
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

        /// Events on the subscription's channel, as hc sent them.
        func send(events: [String]) {
            for line in events {
                feed.yield(HcFrame(channel: 2, kind: .data, payload: Data((line + "\n").utf8)).encoded())
            }
        }

        /// Another client writes `herdr.seen`, in the shape of a captured
        /// `labels` event (the whole map; `Fixtures/hc-events.ndjson`).
        func markedSeen(_ turn: Int, seq: Int) {
            let address = HcPaneModelTests.turnFixture.address
            send(events: [#"{"jsonrpc":"2.0","method":"event","params":{"data":{"labels":{"herdr.seen":"\#(turn)"}},"seq":\#(seq),"terminal":"\#(address)","type":"labels"}}"#])
        }

        var seen: [String] { lock.withLock { seenWrites } }

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

    /// `Fixtures/hc-turn-events.ndjson`: a scratch Claude Code's subscription
    /// reply, then the events of one prompt — status working, title, status
    /// done, `turn` 1, status with its message (captured 13 Nov 2026).
    struct TurnFixture: Sendable {
        let snapshot: HcJSON
        let events: [String]
        let address: String
        let lastSeq: Int
    }

    nonisolated static let turnFixture: TurnFixture = {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Fixtures/hc-turn-events.ndjson")
        let lines = ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        let snapshot = lines.first.flatMap { try? JSONDecoder().decode(HcJSON.self, from: Data($0.utf8))["result"] } ?? .null
        let events = Array(lines.dropFirst())
        let last = events.last.flatMap { try? JSONDecoder().decode(HcJSON.self, from: Data($0.utf8))["params"]?["seq"]?.int } ?? 0
        let address: String = if case .array(let terminals)? = snapshot["terminals"] { terminals.first?["address"]?.string ?? "" } else { "" }
        return TurnFixture(snapshot: snapshot, events: events, address: address, lastSeq: last)
    }()

    private func model(_ cores: [FakeCore], address: String = "t5n") -> (HcPaneModel, () -> Int) {
        var opened = 0
        let model = HcPaneModel(
            address: address,
            open: {
                defer { opened += 1 }
                return cores[min(opened, cores.count - 1)]
            },
            report: { _ in },
            seenRetryDelay: .milliseconds(50)
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

    // MARK: - Seen

    /// The screen on show, live, and following the fixture's terminal; any
    /// seen write from the snapshot has finished.
    private func looking(_ core: FakeCore) async -> HcPaneModel {
        let (model, _) = model([core], address: Self.turnFixture.address)
        model.show(TerminalGrid(cols: 53, rows: 30))
        await eventually { model.record != nil }
        await model.seenWrite?.value
        return model
    }

    /// Waits until the model has read `seen` back off the record, then for
    /// any write that set off.
    private func settle(_ model: HcPaneModel, seen: Int? = nil, turn: Int? = nil) async {
        await eventually {
            (seen == nil || model.record?.seenTurn == seen) && (turn == nil || model.record?.turn == turn)
        }
        await model.seenWrite?.value
    }

    @Test("looking marks each turn seen once, from the captured events, and a later mark-unread stands")
    func marksSeen() async {
        let core = FakeCore()
        let model = await looking(core)
        // Turn 0 with no label: written, so a terminal started elsewhere joins.
        #expect(core.seen == ["0"])

        // A prompt runs and ends, as captured: status, title, status, turn 1.
        core.send(events: Self.turnFixture.events)
        await settle(model, turn: 1)
        #expect(core.seen == ["0", "1"])

        // Another client marks it unread: a screen left on does not overrule it.
        core.markedSeen(0, seq: Self.turnFixture.lastSeq + 1)
        await settle(model, seen: 0)
        #expect(core.seen == ["0", "1"])
        await model.close()
    }

    @Test("a turn already seen is not written again")
    func alreadySeen() async {
        let core = FakeCore()
        if case .object(var result) = core.snapshot, case .array(var terminals)? = result["terminals"],
           case .object(var record)? = terminals.first {
            record["labels"] = .object(["herdr.seen": .string("0")])
            terminals[0] = .object(record)
            result["terminals"] = .array(terminals)
            core.snapshot = .object(result)
        }
        let model = await looking(core)
        #expect(model.record?.seenTurn == 0)
        #expect(core.seen.isEmpty)
        await model.close()
    }

    /// From review: Control Center or a Face ID prompt made every return a
    /// new look, and the next update overruled the Mac's "mark unread".
    @Test("covered for a moment is the same look; back from the background is a new one")
    func presence() async {
        let core = FakeCore()
        let model = await looking(core)
        core.send(events: Self.turnFixture.events)
        await settle(model, turn: 1)
        core.markedSeen(0, seq: Self.turnFixture.lastSeq + 1)
        await settle(model, seen: 0)

        model.setPresence(.covered)
        model.setPresence(.inFront)
        await model.seenWrite?.value
        #expect(core.seen == ["0", "1"], "the mark-unread stands")

        model.setPresence(.background)
        model.setPresence(.inFront)
        await model.seenWrite?.value
        #expect(core.seen == ["0", "1", "1"], "a new look reads it again")
        await model.close()
    }

    @Test("nothing is marked while covered, and it is once in front")
    func covered() async {
        let core = FakeCore()
        let (model, _) = model([core], address: Self.turnFixture.address)
        model.setPresence(.covered)
        model.show(TerminalGrid(cols: 53, rows: 30))
        await eventually { model.record != nil }
        await model.seenWrite?.value
        #expect(core.seen.isEmpty)
        model.setPresence(.inFront)
        await model.seenWrite?.value
        #expect(core.seen == ["0"])
        await model.close()
    }

    /// From review: a failed write waited for the next event, and an idle
    /// `done` agent sends none.
    @Test("a failed write is tried again without waiting for an event")
    func retried() async {
        let core = FakeCore()
        core.labelFailures = 1
        let model = await looking(core)
        await eventually { core.seen == ["0"] }
        #expect(core.seen == ["0"])
        await model.close()
    }

    @Test("when the program ends, nothing is followed and no record is left")
    func endedForgetsRecord() async {
        let core = FakeCore()
        let model = await looking(core)
        #expect(model.record != nil)
        core.endProgram()
        await eventually { model.phase == .ended }
        #expect(model.record == nil)
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
        model.attach { _ in }
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

    /// From review: the composer cleared a long prompt that then had no
    /// stream to go to.
    @Test("a submit with no stream to take it says so")
    func submitWithoutStream() async throws {
        let core = FakeCore()
        let (model, _) = model([core])
        #expect(await model.submit(try #require(SubmittedLine("ls"))) == false)
        model.show(TerminalGrid(cols: 53, rows: 30))
        await eventually { model.phase == .live }
        #expect(await model.submit(try #require(SubmittedLine("ls"))))
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
