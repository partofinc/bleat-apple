import Foundation

/// Cuts a byte stream into frames, however the transport chunked it.
///
/// **Reads by offset, compacts once per push.** Dropping each frame from the
/// front of the buffer as it was read recopied the rest every time — quadratic
/// for a chunk holding many small frames, which is exactly what a burst of
/// CREDIT and DATA looks like.
public struct HcFrameDecoder: Sendable {
    public enum Failure: Error, Sendable, Equatable {
        case oversized(Int)
    }

    private var buffer = Data()

    public init() {}

    /// Adds bytes and returns every frame now complete.
    public mutating func push(_ bytes: Data) throws -> [HcFrame] {
        buffer.append(bytes)
        var frames: [HcFrame] = []
        var offset = buffer.startIndex
        defer {
            if offset > buffer.startIndex { buffer = Data(buffer[offset...]) }
        }
        while buffer.endIndex - offset >= HcFrame.headerSize {
            let channel = buffer.readLittleEndianUInt32(at: offset)
            let kind = buffer[offset + 4]
            let length = Int(buffer.readLittleEndianUInt32(at: offset + 5))
            guard length <= HcFrame.maxPayload else { throw Failure.oversized(length) }
            let payloadStart = offset + HcFrame.headerSize
            guard buffer.endIndex - payloadStart >= length else { break }
            frames.append(HcFrame(channel: channel, rawKind: kind, payload: Data(buffer[payloadStart..<payloadStart + length])))
            offset = payloadStart + length
        }
        return frames
    }
}

extension Data {
    mutating func append(littleEndian value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    func readLittleEndianUInt32(at index: Index) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { value, offset in
            value | UInt32(self[index + offset]) << (8 * UInt32(offset))
        }
    }
}
