import Foundation

/// One NDJSON record on a `terminal session control` / `observe` stdout stream.
///
/// Verified against herdr 0.8.2. The only record type observed so far is
/// `terminal.frame`; anything else decodes to `.unknown(type:)` so that a new
/// server-side record never crashes the client.
public enum TerminalRecord: Sendable {
    case frame(TerminalFrame)
    case unknown(type: String)

    private enum TypeKey: String, CodingKey { case type }
}

extension TerminalRecord: Decodable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: TypeKey.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "terminal.frame":
            self = .frame(try TerminalFrame(from: decoder))
        default:
            self = .unknown(type: type)
        }
    }
}

/// A rendered screen or delta for a pane.
///
/// `bytes` is base64-encoded ANSI. There is **no separate cursor field**: the
/// cursor position is carried inside the escape sequences, so the payload must
/// reach the renderer untouched.
public struct TerminalFrame: Decodable, Sendable {
    /// Base64 ANSI as it arrived on the wire.
    public let base64: String
    /// `"ansi"` for every frame observed so far.
    public let encoding: String
    /// `true` for the full-screen replay sent on attach; deltas follow.
    public let full: Bool
    public let width: Int
    public let height: Int
    public let seq: Int

    enum CodingKeys: String, CodingKey {
        case base64 = "bytes"
        case encoding, full, width, height, seq
    }

    /// The decoded ANSI byte stream, ready to hand to a renderer.
    ///
    /// Returns `nil` only if the host sent malformed base64.
    public var data: Data? {
        Data(base64Encoded: base64)
    }
}
