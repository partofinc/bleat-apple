import Foundation
import Testing
@testable import BleatKit

@Suite("herdr-core: the client over a byte stream")
struct HcClientTests {

    /// Plays the core's side: what the client writes is recorded, and the test
    /// decides what comes back and in which chunks.
    final class ScriptedCore: DuplexStream, @unchecked Sendable {
        let output: AsyncThrowingStream<Data, any Error>
        private let feed: AsyncThrowingStream<Data, any Error>.Continuation
        private let lock = NSLock()
        private var written = Data()
        private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

        init() {
            (output, feed) = AsyncThrowingStream<Data, any Error>.makeStream()
        }

        func send(_ data: Data) async throws {
            let ready = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                written.append(data)
                let ready = waiters.filter { $0.0 <= written.count }.map(\.1)
                waiters.removeAll { $0.0 <= written.count }
                return ready
            }
            ready.forEach { $0.resume() }
        }

        func close() async { feed.finish() }

        func reply(_ data: Data) { feed.yield(data) }
        func end(throwing error: (any Error)? = nil) { feed.finish(throwing: error) }

        /// Waits until the client has written at least `count` bytes.
        func written(atLeast count: Int) async -> Data {
            await withCheckedContinuation { continuation in
                let done = lock.withLock { () -> Bool in
                    if written.count >= count { return true }
                    waiters.append((count, continuation))
                    return false
                }
                if done { continuation.resume() }
            }
            return lock.withLock { written }
        }

        /// Waits until the client has written at least `count` frames after
        /// its hello line, and returns them.
        ///
        /// **One snapshot for both the frames and the byte count.** Reading
        /// them apart let a write land in between: the frames needed had
        /// arrived, and the wait was for one byte beyond them, which never
        /// came — a hang in about one run in eight.
        func frames(atLeast count: Int) async throws -> [HcFrame] {
            while true {
                let snapshot = lock.withLock { written }
                let frames = try Self.frames(in: snapshot)
                if frames.count >= count { return frames }
                _ = await self.written(atLeast: snapshot.count + 1)
            }
        }

        /// The frames written after the hello line.
        func frames() async throws -> [HcFrame] {
            try Self.frames(in: lock.withLock { written })
        }

        private static func frames(in all: Data) throws -> [HcFrame] {
            guard let newline = all.firstIndex(of: UInt8(ascii: "\n")) else { return [] }
            var decoder = HcFrameDecoder()
            return try decoder.push(Data(all[all.index(after: newline)...]))
        }
    }

    private let helloReply = Data(#"{"jsonrpc":"2.0","id":0,"result":{"framed":true,"generation":1,"version":"0.1.20","core":{"id":"abc","name":"kestrel"},"features":["framed","events"]}}"#.utf8) + Data("\n".utf8)

    private func json(_ text: String) -> Data { Data(text.utf8) }

    private func connected() async throws -> (HcClient, ScriptedCore) {
        let core = ScriptedCore()
        async let client = HcClient.connect(over: core)
        let hello = await core.written(atLeast: 1)
        let line = try #require(hello.split(separator: UInt8(ascii: "\n")).first)
        let request = try JSONDecoder().decode(HcJSON.self, from: Data(line))
        #expect(request["method"]?.string == "hello")
        #expect(request["params"]?["framed"] == .bool(true))
        core.reply(helloReply)
        return (try await client, core)
    }

    @Test("hello asks for framed mode and reads the core")
    func handshake() async throws {
        let (client, _) = try await connected()
        let hello = await client.hello
        #expect(hello?.version == "0.1.20")
        #expect(hello?.coreName == "kestrel")
        #expect(hello?.features == ["framed", "events"])
        await client.close()
    }

    @Test("a core that will not frame is refused")
    func notFramed() async throws {
        let core = ScriptedCore()
        let client = Task { try await HcClient.connect(over: core) }
        _ = await core.written(atLeast: 1)
        core.reply(json(#"{"jsonrpc":"2.0","id":0,"result":{"framed":false,"generation":1}}"#) + json("\n"))
        await #expect(throws: HcProtocolError.notFramed) { try await client.value }
    }

    @Test("another protocol generation is refused by name")
    func otherGeneration() async throws {
        let core = ScriptedCore()
        let client = Task { try await HcClient.connect(over: core) }
        _ = await core.written(atLeast: 1)
        core.reply(json(#"{"jsonrpc":"2.0","id":0,"result":{"framed":true,"generation":2}}"#) + json("\n"))
        await #expect(throws: HcProtocolError.unsupportedGeneration(2)) { try await client.value }
    }

    /// The first frames can arrive in the same chunk as the hello reply.
    @Test("frames glued to the hello line are not lost")
    func framesAfterHelloInOneChunk() async throws {
        let core = ScriptedCore()
        async let connecting = HcClient.connect(over: core)
        _ = await core.written(atLeast: 1)
        let early = HcFrame(channel: 4, kind: .data, payload: json("early\n"))
        core.reply(helloReply + early.encoded())
        let client = try await connecting
        var iterator = await client.channel(4).makeAsyncIterator()
        #expect(try await iterator.next() == json("early\n"))
        await client.close()
    }

    @Test("a call is answered by id, and an error reply throws HcError with its kind")
    func callsAndErrors() async throws {
        let (client, core) = try await connected()
        async let first = client.call("terminal.get", ["terminal": .string("t1")])
        async let second = client.call("terminal.get", ["terminal": .string("t404")])
        let requests = try await core.frames(atLeast: 2)
        let ids = try requests.map { try JSONDecoder().decode(HcJSON.self, from: $0.payload) }
        let byTerminal = Dictionary(uniqueKeysWithValues: ids.map { ($0["params"]?["terminal"]?.string ?? "", $0["id"]?.number ?? -1) })
        let okID = Int(try #require(byTerminal["t1"]))
        let badID = Int(try #require(byTerminal["t404"]))
        // Answered in the opposite order to the calls.
        core.reply(HcFrame(channel: 0, kind: .data, payload: json(#"{"jsonrpc":"2.0","id":\#(badID),"error":{"code":-32000,"message":"no terminal t404","data":{"kind":"not_found"}}}"#)).encoded())
        core.reply(HcFrame(channel: 0, kind: .data, payload: json(#"{"jsonrpc":"2.0","id":\#(okID),"result":{"address":"t1"}}"#)).encoded())
        #expect(try await first["address"]?.string == "t1")
        do {
            _ = try await second
            Issue.record("expected an error")
        } catch let error as HcError {
            #expect(error.kind == "not_found")
            #expect(error.method == "terminal.get")
            #expect(error.message == "no terminal t404")
        }
        await client.close()
    }

    /// The subscribe request the client sent, and its id.
    private func subscribeRequest(_ core: ScriptedCore) async throws -> Int {
        let frame = try #require(try await core.frames(atLeast: 1).first)
        let request = try JSONDecoder().decode(HcJSON.self, from: frame.payload)
        #expect(request["method"]?.string == "events.subscribe")
        return try #require(request["id"]?.int)
    }

    /// A subscription's first events can follow its reply before the caller
    /// has opened the channel; they must wait for it. Credit is owed only once
    /// the caller has dealt with them — granted on arrival, a stalled consumer
    /// never filled the core's window and buffered without limit.
    @Test("early events wait for the channel, and are credited only once consumed")
    func subscriptionAndCredit() async throws {
        let (client, core) = try await connected()
        async let subscribing = client.subscribe()
        let id = try await subscribeRequest(core)
        let event = json(#"{"jsonrpc":"2.0","method":"event","params":{"type":"title","terminal":"t1","seq":6,"data":{"title":"x"}}}"#) + json("\n")
        core.reply(
            HcFrame(channel: 0, kind: .data, payload: json(#"{"jsonrpc":"2.0","id":\#(id),"result":{"channel":1,"seq":5,"terminals":[]}}"#)).encoded()
                + HcFrame(channel: 1, kind: .data, payload: event).encoded()
        )
        let subscription = try await subscribing
        #expect(subscription.snapshot["seq"] == .number(5))
        var iterator = subscription.notifications.makeAsyncIterator()
        guard case .event(let params)? = try await iterator.next() else {
            Issue.record("expected the early event")
            return
        }
        #expect(params["terminal"]?.string == "t1")
        #expect(try await core.frames().allSatisfy { $0.knownKind != .credit }, "not consumed yet")

        // Coming back for the next line is what says the last one was dealt with.
        let waiting = Task { [iterator] in
            var iterator = iterator
            return try await iterator.next()
        }
        let credit = try await core.frames(atLeast: 2).first { $0.knownKind == .credit }
        #expect(credit?.channel == 1)
        #expect(credit.map { Array($0.payload) } == Array(HcFrame.credit(event.count, on: 1).payload))
        await client.close()
        _ = try? await waiting.value
    }

    /// Dropped once: the subscription then sat "live" on a dead channel.
    @Test("a channel the core closed before anyone listened still ends")
    func closedBeforeListening() async throws {
        let (client, core) = try await connected()
        // A call answered after the frames: once it returns, the reader has
        // taken them, so the channel is opened only after its CLOSE arrived.
        let pending = Task { try await client.call("server.status") }
        let request = try JSONDecoder().decode(HcJSON.self, from: try #require(try await core.frames(atLeast: 1).first).payload)
        let id = try #require(request["id"]?.int)
        core.reply(
            HcFrame(channel: 9, kind: .data, payload: json("last\n")).encoded()
                + HcFrame(channel: 9, kind: .close).encoded()
                + HcFrame(channel: 0, kind: .data, payload: json(#"{"jsonrpc":"2.0","id":\#(id),"result":{}}"#)).encoded()
        )
        _ = try await pending.value
        var iterator = await client.channel(9).makeAsyncIterator()
        #expect(try await iterator.next() == json("last\n"))
        #expect(try await iterator.next() == nil)
        await client.close()
    }

    @Test("a channel number that is not one is refused, not trapped on")
    func badChannelNumber() async throws {
        let (client, core) = try await connected()
        let subscribing = Task { try await client.subscribe() }
        let id = try await subscribeRequest(core)
        core.reply(HcFrame(channel: 0, kind: .data, payload: json(#"{"jsonrpc":"2.0","id":\#(id),"result":{"channel":-1,"seq":1}}"#)).encoded())
        await #expect(throws: HcProtocolError.notFramed) { try await subscribing.value }
        await client.close()
    }

    @Test("the stream ending fails every open call")
    func endFailsCalls() async throws {
        let (client, core) = try await connected()
        let pending = Task { try await client.call("server.status") }
        _ = try await core.frames(atLeast: 1)
        core.end(throwing: TransportError.channelClosed)
        await #expect(throws: TransportError.channelClosed) { try await pending.value }
        await #expect(throws: TransportError.channelClosed) { try await client.call("server.status") }
    }
}
