import Foundation

/// Which way a scroll request moves the viewport.
public enum ScrollDirection: String, Codable, Sendable {
    case up, down
}

/// A record written to the stdin side of a `terminal session control` stream.
///
/// Verified against herdr 0.8.2 on a scratch pane: these four are the complete
/// set the host accepts. An unrecognized record — or one missing a required
/// field — is *ignored* with a warning on stderr; it does not close the stream.
public enum TerminalCommand: Sendable {
    /// Literal text to type into the pane.
    case text(String)
    /// Raw bytes, base64-encoded on the wire, for keys text cannot express
    /// (arrows, Ctrl-C, and the rest of the Phase 3 accessory row).
    case bytes(Data)
    case resize(cols: Int, rows: Int)
    /// Both fields are required by the host, and `lines` is only honoured
    /// against herdr's own history. For a full-screen program herdr sends one
    /// wheel event per record whatever it says (measured on 0.9.3). `observe`
    /// ignores the record entirely.
    case scroll(direction: ScrollDirection, lines: Int)
    /// Give up input ownership. The host closes the stream and the command
    /// exits 0, so this is the clean detach path — no need to kill the channel.
    case release
}

extension TerminalCommand: Encodable {
    enum CodingKeys: String, CodingKey {
        case type, text, bytes, cols, rows, direction, lines
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
        case .scroll(let direction, let lines):
            try c.encode("terminal.scroll", forKey: .type)
            try c.encode(direction, forKey: .direction)
            try c.encode(lines, forKey: .lines)
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
