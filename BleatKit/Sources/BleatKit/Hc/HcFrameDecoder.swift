import Foundation

/// Cuts a byte stream into frames, however the transport chunked it.
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
        while buffer.count >= HcFrame.headerSize {
            let start = buffer.startIndex
            let channel = buffer.readLittleEndianUInt32(at: start)
            let kind = buffer[start + 4]
            let length = Int(buffer.readLittleEndianUInt32(at: start + 5))
            guard length <= HcFrame.maxPayload else { throw Failure.oversized(length) }
            guard buffer.count >= HcFrame.headerSize + length else { break }
            let payloadStart = start + HcFrame.headerSize
            let payload = Data(buffer[payloadStart..<payloadStart + length])
            frames.append(HcFrame(channel: channel, rawKind: kind, payload: payload))
            buffer = Data(buffer[(payloadStart + length)...])
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
