import Foundation

/// Reassembles newline-delimited JSON from arbitrarily chunked transport reads.
///
/// A single `terminal.frame` is several kilobytes of base64, so it will not
/// arrive in one read; conversely one read may carry several frames. Feed every
/// chunk in and take whatever complete lines come out.
public struct NDJSONSplitter: Sendable {
    private var buffer = Data()
    private let byteLimit: Int

    /// - Parameter byteLimit: Guard against a host that never sends a newline.
    ///   Exceeding it throws rather than growing without bound.
    public init(byteLimit: Int = 8 * 1024 * 1024) {
        self.byteLimit = byteLimit
    }

    /// Append a chunk and return every complete line it completed.
    ///
    /// Blank lines are skipped: they carry no record and decoding them would
    /// surface a spurious contract error.
    public mutating func push(_ chunk: Data) throws -> [Data] {
        buffer.append(chunk)
        guard buffer.count <= byteLimit else {
            buffer.removeAll(keepingCapacity: false)
            throw TransportError.oversizedRecord(limit: byteLimit)
        }

        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer = buffer[buffer.index(after: newline)...]
            if !line.isEmpty { lines.append(Data(line)) }
        }
        // Re-base so repeated slicing does not keep the original allocation.
        buffer = Data(buffer)
        return lines
    }

    /// Any trailing bytes not terminated by a newline. A well-behaved stream
    /// ends empty; leftovers mean the channel was cut mid-record.
    public var pending: Data { buffer }
}
