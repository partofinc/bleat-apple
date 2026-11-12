import Foundation

/// One frame of hc's framed mode: `[channel u32 LE][kind u8][len u32 LE][payload]`.
///
/// From herdr-core's `wire.rs`, and checked live against hc 0.1.20 over
/// `hc connect` (`docs/hc-facts.md`). Channel 0 carries JSON-RPC, one message
/// per DATA frame; an event subscription and each attach get channels of their
/// own, with credit.
public struct HcFrame: Sendable, Equatable {
    public enum Kind: UInt8, Sendable {
        case data = 0
        /// u32 LE: how many bytes of this channel's DATA the receiver consumed.
        case credit = 1
        /// JSON reason from the core; empty from a client.
        case close = 2
        /// u16 LE cols, u16 LE rows.
        case resize = 3
        /// One byte: 1 gained, 0 lost.
        case focus = 4
        /// JSON display facts.
        case facts = 5
        /// Replies the terminal generated itself, not a person typing.
        case automaticInput = 6
    }

    public static let headerSize = 9
    /// `wire.rs`'s `MAX_PAYLOAD`. A larger length is a stream gone wrong, not
    /// a frame to allocate for.
    public static let maxPayload = 16 << 20
    /// `wire.rs`'s `WINDOW`: the credit each stream starts with.
    public static let window = 256 * 1024

    public var channel: UInt32
    /// The raw kind byte. Kept raw so a kind this build does not know is
    /// skipped rather than fatal; `knownKind` reads it.
    public var kind: UInt8
    public var payload: Data

    public init(channel: UInt32, kind: Kind, payload: Data = Data()) {
        self.init(channel: channel, rawKind: kind.rawValue, payload: payload)
    }

    public init(channel: UInt32, rawKind: UInt8, payload: Data) {
        self.channel = channel
        self.kind = rawKind
        self.payload = payload
    }

    public var knownKind: Kind? { Kind(rawValue: kind) }

    public func encoded() -> Data {
        var out = Data(capacity: Self.headerSize + payload.count)
        out.append(littleEndian: channel)
        out.append(kind)
        out.append(littleEndian: UInt32(payload.count))
        out.append(payload)
        return out
    }

    /// A CREDIT frame granting `bytes` back on `channel`.
    public static func credit(_ bytes: Int, on channel: UInt32) -> HcFrame {
        var payload = Data()
        payload.append(littleEndian: UInt32(clamping: bytes))
        return HcFrame(channel: channel, kind: .credit, payload: payload)
    }
}
