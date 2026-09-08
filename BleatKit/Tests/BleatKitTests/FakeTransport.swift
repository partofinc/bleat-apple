import BleatKit
import Foundation

/// Replays captured fixtures in place of a real host.
struct FakeTransport: HerdrTransport {
    /// Keyed by the joined command, e.g. `"agent list"`.
    var responses: [String: Data] = [:]
    /// Chunks handed to `openStream`, in order. Chunk boundaries are deliberate:
    /// they exercise record reassembly.
    var streamChunks: [Data] = []

    func run(_ args: [String]) async throws -> Data {
        guard let data = responses[args.joined(separator: " ")] else {
            throw HerdrError(
                command: args,
                exitCode: 2,
                stderr: "unknown command: \(args.joined(separator: " "))"
            )
        }
        return data
    }

    func openStream(_ args: [String]) async throws -> any HerdrStream {
        FakeStream(chunks: streamChunks)
    }
}

final class FakeStream: HerdrStream, @unchecked Sendable {
    private let chunks: [Data]
    /// Everything the client wrote to stdin, for asserting on input records.
    private(set) var written: [Data] = []
    private(set) var closed = false

    init(chunks: [Data]) { self.chunks = chunks }

    var output: AsyncThrowingStream<Data, any Error> {
        AsyncThrowingStream { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
    }

    func send(_ data: Data) async throws { written.append(data) }
    func close() async { closed = true }
}

/// Records what was sent, for the commands that are writes.
///
/// `FakeTransport` answers by exact command string, which is all a read needs:
/// getting the arguments wrong simply fails to match. A write is the other way
/// round — the flags *are* the behaviour, and `--no-focus` reaching the host is
/// the assertion rather than an implementation detail — so this one takes any
/// command, answers with the same reply, and keeps the log.
final class RecordingTransport: HerdrTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [[String]] = []
    private let reply: Data

    /// Everything asked of the host, in order.
    var commands: [[String]] { lock.withLock { log } }

    init(reply: Data = Data()) { self.reply = reply }

    func run(_ args: [String]) async throws -> Data {
        lock.withLock { log.append(args) }
        return reply
    }

    func openStream(_ args: [String]) async throws -> any HerdrStream {
        lock.withLock { log.append(args) }
        return FakeStream(chunks: [])
    }
}
