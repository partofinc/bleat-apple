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
