import Foundation

/// A terminal's screen as text, from `terminal.read`
/// (`Fixtures/hc-terminal-read.json`): `{text, how, complete}`.
///
/// For a device that cannot attach — the watch reads a terminal this way,
/// one call at a time. Text, not bytes: hc renders the screen itself, so
/// there are no escape sequences to interpret.
public struct HcScreenText: Sendable, Equatable {
    public let text: String

    public init(text: String) { self.text = text }

    public init(reply: HcJSON) throws {
        guard let text = reply["text"]?.string else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "terminal.read's reply has no text"))
        }
        self.text = text
    }

    /// The last `count` lines with something on them, blank lines between
    /// them kept: what fits on a small screen is the bottom, where the
    /// prompt and an agent's question are.
    public func lastLines(_ count: Int) -> [String] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            String(line.reversed().drop { $0 == " " }.reversed())
        }
        guard let last = lines.lastIndex(where: { !$0.isEmpty }) else { return [] }
        return Array(lines[...last].suffix(count))
    }
}
