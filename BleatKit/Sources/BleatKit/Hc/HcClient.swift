import Foundation

/// A connection to herdr-core, speaking its framed JSON-RPC over one byte
/// stream — `hc connect` on an SSH exec channel, or anything else that carries
/// the same bytes.
///
/// **Framed from the first reply.** `hello` with `framed: true` goes as one
/// plain JSON line and is answered by one; everything after is frames
/// (`HcFrame`). A plain connection cannot do this job: once it subscribes to
/// events it "carries only notifications" (the schema's `SubscribeResult`), so
/// the requests would need a second connection.
///
/// **One reader, one writer.** The reader task owns the stream's output and is
/// the only thing that reads it; the writer task sends queued frames in order.
/// A call registers for its reply *before* its frame is queued, so a reply that
/// races back cannot arrive with nobody waiting for it.
///
/// Not reusable after the stream ends: every call and channel fails with the
/// reason, and the caller dials again. `hello` is cheap and the subscription
/// snapshot rebuilds everything, which is what makes reconnecting the
/// recovery path.
public actor HcClient {
    /// What `hello` said about the core.
    public struct Hello: Sendable, Equatable {
        public let coreID: String?
        public let coreName: String?
        public let version: String?
        public let generation: Int
        public let features: [String]
    }

    /// The protocol generation this build speaks.
    public static let generation = 1

    private let stream: any DuplexStream
    private let outgoing: AsyncStream<Data>.Continuation
    private var reader: Task<Void, Never>?
    private var writer: Task<Void, Never>?

    private var handshake = Data()
    private var helloWaiter: CheckedContinuation<HcJSON, any Error>?
    private var helloReply: Result<HcJSON, any Error>?
    private var frames = HcFrameDecoder()

    private var nextID = 1
    private var pending: [Int: (method: String, continuation: CheckedContinuation<HcJSON, any Error>)] = [:]
    private var channels: [UInt32: AsyncThrowingStream<Data, any Error>.Continuation] = [:]
    /// DATA for a channel nobody has opened yet. A subscription's first events
    /// can follow its reply before the caller has had a turn to listen.
    /// Bounded by the core's window: nothing here grants credit for it.
    private var early: [UInt32: [Data]] = [:]
    /// Channels the core closed before anyone opened them. Without this the
    /// close was dropped, and the channel opened later never finished.
    private var closedEarly: Set<UInt32> = []
    /// Channels whose listener went away. Their late DATA is dropped rather
    /// than kept in `early` for good, and the core is told to close them.
    private var abandoned: Set<UInt32> = []
    private var failure: (any Error)?

    public private(set) var hello: Hello?

    private init(stream: any DuplexStream) {
        self.stream = stream
        let (queue, continuation) = AsyncStream<Data>.makeStream()
        outgoing = continuation
        writer = Task { [stream] in
            for await data in queue {
                // A failed write ends the stream, which the reader reports.
                do { try await stream.send(data) } catch { break }
            }
        }
    }

    /// Shakes hands over `stream` and returns a client on it.
    ///
    /// - Throws: `HcProtocolError` when the core will not speak framed mode or
    ///   speaks another generation; the stream's own error when it ends first.
    public static func connect(over stream: any DuplexStream) async throws -> HcClient {
        let client = HcClient(stream: stream)
        do {
            try await client.start()
        } catch {
            await client.close()
            throw error
        }
        return client
    }

    private func start() async throws {
        reader = Task { [stream] in
            do {
                for try await chunk in stream.output {
                    await self.receive(chunk)
                }
                await self.fail(HcProtocolError.closed)
            } catch {
                await self.fail(error)
            }
        }
        let request: HcJSON = .object([
            "jsonrpc": .string("2.0"), "id": .number(0), "method": .string("hello"),
            "params": .object(["framed": .bool(true), "generation": .number(Double(Self.generation))]),
        ])
        outgoing.yield(try JSONEncoder().encode(request) + Data("\n".utf8))

        let reply = try await withCheckedThrowingContinuation { continuation in
            if let ready = helloReply {
                continuation.resume(with: ready)
            } else {
                helloWaiter = continuation
            }
        }
        if let error = reply["error"] {
            // As lenient as `call`: a refusal without a well-formed message is
            // still a refusal, not contract drift.
            var refused = (try? error.decode(HcError.self)) ?? HcError(code: error["code"]?.int ?? 0, message: "herdr-core refused the handshake")
            refused.method = "hello"
            throw refused
        }
        guard let result = reply["result"] else { throw HcProtocolError.noHello }
        guard case .bool(true)? = result["framed"] else { throw HcProtocolError.notFramed }
        let generation = result["generation"]?.int ?? 0
        guard generation == Self.generation else { throw HcProtocolError.unsupportedGeneration(generation) }
        var features: [String] = []
        if case .array(let listed)? = result["features"] { features = listed.compactMap(\.string) }
        hello = Hello(
            coreID: result["core"]?["id"]?.string,
            coreName: result["core"]?["name"]?.string,
            version: result["version"]?.string,
            generation: generation,
            features: features
        )
    }

    // MARK: - Calls

    /// Calls `method` on channel 0 and returns its `result`.
    ///
    /// - Throws: `HcError` when the core answers with an error, or why the
    ///   connection ended.
    public func call(_ method: String, _ params: [String: HcJSON] = [:]) async throws -> HcJSON {
        if let failure { throw failure }
        let id = nextID
        nextID += 1
        let request: HcJSON = .object([
            "jsonrpc": .string("2.0"), "id": .number(Double(id)),
            "method": .string(method), "params": .object(params),
        ])
        let frame = HcFrame(channel: 0, kind: .data, payload: try JSONEncoder().encode(request))
        let reply = try await withCheckedThrowingContinuation { continuation in
            pending[id] = (method, continuation)
            outgoing.yield(frame.encoded())
        }
        if let error = reply["error"] {
            var refused = (try? error.decode(HcError.self)) ?? HcError(code: 0, message: "herdr-core refused \(method)")
            refused.method = method
            throw refused
        }
        return reply["result"] ?? .null
    }

    // MARK: - Channels

    /// The DATA arriving on `channel`.
    ///
    /// **The consumer grants credit, with `grant(_:on:)`, once it has dealt
    /// with a chunk.** Granting it here, as the chunk went into this stream's
    /// buffer, meant a consumer that stalled never let the core's window fill:
    /// the core never fell back to a repaint (`wire.rs`, `MAX_PENDING`), and
    /// the buffer grew without limit. Granted after use, a stalled consumer
    /// stops the credit, and the core stops sending.
    public func channel(_ channel: UInt32) -> AsyncThrowingStream<Data, any Error> {
        let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        if let failure {
            continuation.finish(throwing: failure)
            return stream
        }
        channels[channel] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.forget(channel) }
        }
        abandoned.remove(channel)
        for data in early.removeValue(forKey: channel) ?? [] {
            continuation.yield(data)
        }
        if closedEarly.remove(channel) != nil {
            channels[channel] = nil
            continuation.finish()
        }
        return stream
    }

    /// Returns `bytes` of credit on `channel`: the consumer has dealt with
    /// that much of what arrived.
    public func grant(_ bytes: Int, on channel: UInt32) {
        guard failure == nil, bytes > 0 else { return }
        outgoing.yield(HcFrame.credit(bytes, on: channel).encoded())
    }

    /// Sends a frame on a channel: keys, a resize, a close.
    public func send(_ frame: HcFrame) throws {
        if let failure { throw failure }
        outgoing.yield(frame.encoded())
    }

    /// The listener went away: close the channel at the core, and drop what
    /// still arrives on it.
    private func forget(_ channel: UInt32) {
        guard channels.removeValue(forKey: channel) != nil else { return }
        abandoned.insert(channel)
        guard failure == nil else { return }
        outgoing.yield(HcFrame(channel: channel, kind: .close).encoded())
    }

    // MARK: - Reading

    private func receive(_ chunk: Data) {
        guard hello != nil || helloReply != nil else {
            handshake.append(chunk)
            guard let newline = handshake.firstIndex(of: UInt8(ascii: "\n")) else { return }
            let line = handshake[..<newline]
            let rest = handshake[handshake.index(after: newline)...]
            let reply = Result { try JSONDecoder().decode(HcJSON.self, from: Data(line)) }
            helloReply = reply
            helloWaiter?.resume(with: reply)
            helloWaiter = nil
            handshake = Data()
            if !rest.isEmpty { take(Data(rest)) }
            return
        }
        take(chunk)
    }

    private func take(_ bytes: Data) {
        let decoded: [HcFrame]
        do {
            decoded = try frames.push(bytes)
        } catch {
            fail(error)
            return
        }
        for frame in decoded {
            switch (frame.channel, frame.knownKind) {
            case (0, .data):
                reply(frame.payload)
            case (let channel, .data):
                deliver(frame.payload, on: channel)
            case (let channel, .close):
                if let continuation = channels.removeValue(forKey: channel) {
                    continuation.finish()
                } else if !abandoned.contains(channel) {
                    closedEarly.insert(channel)
                }
            default:
                // CREDIT, RESIZE, FOCUS, FACTS from the core: nothing here
                // acts on them yet, and an unknown kind is skipped.
                break
            }
        }
    }

    private func reply(_ payload: Data) {
        guard let message = try? JSONDecoder().decode(HcJSON.self, from: payload),
              let id = message["id"]?.int,
              let waiter = pending.removeValue(forKey: id)
        else { return }
        waiter.continuation.resume(returning: message)
    }

    private func deliver(_ data: Data, on channel: UInt32) {
        if let continuation = channels[channel] {
            continuation.yield(data)
        } else if !abandoned.contains(channel) {
            early[channel, default: []].append(data)
        }
    }

    private func fail(_ error: any Error) {
        guard failure == nil else { return }
        failure = error
        helloWaiter?.resume(throwing: error)
        helloWaiter = nil
        if helloReply == nil { helloReply = .failure(error) }
        for (_, waiter) in pending { waiter.continuation.resume(throwing: error) }
        pending = [:]
        for (_, continuation) in channels { continuation.finish(throwing: error) }
        channels = [:]
        outgoing.finish()
    }

    /// Ends the connection. Every call and channel still open fails with
    /// `HcProtocolError.closed`. Idempotent.
    public func close() async {
        fail(HcProtocolError.closed)
        reader?.cancel()
        writer?.cancel()
        await stream.close()
    }
}
