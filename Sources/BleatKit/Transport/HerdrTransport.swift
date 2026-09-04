import Foundation

/// How BleatKit reaches a host running Herdr.
///
/// Nothing above this protocol may know the transport is SSH. Phase 4 adds a
/// second implementation without touching `HerdrClient`.
public protocol HerdrTransport: Sendable {
    /// Run one `herdr` command to completion and return its stdout.
    ///
    /// Throws `HerdrError` on non-zero exit, with stderr attached.
    func run(_ args: [String]) async throws -> Data

    /// Open a long-lived NDJSON channel, e.g. `terminal session control`.
    func openStream(_ args: [String]) async throws -> any HerdrStream
}

/// A bidirectional channel to one long-running `herdr` command.
public protocol HerdrStream: Sendable {
    /// Raw stdout chunks. Chunk boundaries are arbitrary — feed them through
    /// `NDJSONSplitter`, never assume one chunk is one record.
    var output: AsyncThrowingStream<Data, any Error> { get }

    /// Write to the command's stdin.
    func send(_ data: Data) async throws

    /// Close the channel. Callers should send `.release` first when they hold
    /// input ownership.
    func close() async
}

extension HerdrStream {
    /// Convenience for the typed input records.
    public func send(_ command: TerminalCommand) async throws {
        try await send(command.ndjsonLine())
    }

    /// Decoded records, with partial reads reassembled.
    ///
    /// Unrecognized record types surface as `.unknown` rather than throwing.
    public var records: AsyncThrowingStream<TerminalRecord, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var splitter = NDJSONSplitter()
                let decoder = JSONDecoder()
                do {
                    for try await chunk in output {
                        for line in try splitter.push(chunk) {
                            continuation.yield(try decoder.decode(TerminalRecord.self, from: line))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
