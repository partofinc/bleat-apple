import Foundation

/// A record written to the stdin side of a `terminal session control` stream.
///
/// - Warning: The wire shape here is taken from the project notes and has
///   **not** yet been confirmed against a live host — the stream protocol is
///   absent from `api schema --json`, and confirming it requires owning input
///   on a pane. Verify against a scratch pane before relying on it.
public enum TerminalCommand: Sendable {
    /// Literal text to type into the pane.
    case text(String)
    /// Raw bytes, base64-encoded on the wire, for keys text cannot express.
    case bytes(Data)
    case resize(cols: Int, rows: Int)
    case scroll(offsetFromBottom: Int)
    /// Give up input ownership. Sent by `bleat attach` on Ctrl-].
    case release
}

extension TerminalCommand: Encodable {
    enum CodingKeys: String, CodingKey {
        case type, text, bytes, cols, rows, offset_from_bottom
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let value):
            try c.encode("terminal.input", forKey: .type)
            try c.encode(value, forKey: .text)
        case .bytes(let value):
            try c.encode("terminal.input", forKey: .type)
            try c.encode(value.base64EncodedString(), forKey: .bytes)
        case .resize(let cols, let rows):
            try c.encode("terminal.resize", forKey: .type)
            try c.encode(cols, forKey: .cols)
            try c.encode(rows, forKey: .rows)
        case .scroll(let offset):
            try c.encode("terminal.scroll", forKey: .type)
            try c.encode(offset, forKey: .offset_from_bottom)
        case .release:
            try c.encode("terminal.release", forKey: .type)
        }
    }

    /// Encoded as a single NDJSON line, newline included.
    public func ndjsonLine() throws -> Data {
        var data = try JSONEncoder().encode(self)
        data.append(0x0A)
        return data
    }
}
