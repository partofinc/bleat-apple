import Foundation

/// A channel's JSON lines, read only as fast as they are asked for, with
/// credit granted once a chunk's lines have all been taken.
///
/// Pull-based on purpose. A task that pushed lines into a stream as they
/// arrived would have to credit them on arrival — a stalled consumer would then
/// never fill the core's window, and nothing would bound the buffer. Here a
/// chunk is credited when the consumer comes back for the line after its last
/// one, which is when it has dealt with them.
actor HcLineReader {
    private var chunks: AsyncThrowingStream<Data, any Error>.AsyncIterator
    private var splitter = NDJSONSplitter()
    private var lines: [Data] = []
    /// Bytes of the chunk whose lines are being handed out, owed as credit.
    private var owed = 0
    private let client: HcClient
    private let channel: UInt32

    init(_ stream: AsyncThrowingStream<Data, any Error>, client: HcClient, channel: UInt32) {
        chunks = stream.makeAsyncIterator()
        self.client = client
        self.channel = channel
    }

    /// The next line, or nil once the channel has ended.
    func next() async throws -> Data? {
        while lines.isEmpty {
            if owed > 0 {
                await client.grant(owed, on: channel)
                owed = 0
            }
            // Copied out and back: an actor's stored iterator cannot be
            // passed `inout` across a suspension. One consumer, so nothing
            // else touches it meanwhile.
            var iterator = chunks
            let chunk = try await iterator.next(isolation: self)
            chunks = iterator
            guard let chunk else { return nil }
            lines = try splitter.push(chunk)
            owed = chunk.count
        }
        return lines.removeFirst()
    }
}
