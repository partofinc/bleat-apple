import Foundation

/// A pane's screen as plain text, for a reader that reflows instead of panning.
///
/// The terminal view renders what the agent actually drew; this is the other
/// reading of the same pane, and it is lossy on purpose. Colour is gone, and so
/// is any structure that lived in the escape sequences.
///
/// **It cannot recover logical lines, and no option here would.** `pane read`
/// offers `recent-unwrapped`, which undoes the wrapping the *terminal* did to a
/// line too long for the grid — but an agent TUI wraps its own prose to the pane
/// width and indents the continuations itself, so those are real newlines in the
/// pty by the time herdr sees them. Measured on a 142-column pane: `visible` and
/// `recent-unwrapped` differed by one trailing space across 40 lines. Unwrapped
/// is still the right source, because it does help a plain shell that echoed a
/// long command, and it costs nothing where it cannot.
public enum PaneText {
    /// Splits a `pane read --format text` payload into lines.
    ///
    /// **Decoding is total rather than throwing.** `--lines N` cuts the buffer
    /// at a line boundary, not a byte one, but the screen is full of
    /// box-drawing characters and a single truncated multi-byte sequence should
    /// cost one glyph rather than the whole snapshot — there is no better
    /// answer available, and an empty reader would say nothing about why.
    public static func lines(from data: Data) -> [String] {
        var lines = String(decoding: data, as: UTF8.self)
            // A `\r\n` would otherwise leave a carriage return at the end of
            // every line, which renders as a blank glyph. Not seen from this
            // herdr, and cheap to be right about.
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        // The payload ends in a newline, and a terminal's bottom rows are
        // usually empty besides. In a scroll view anchored to the bottom those
        // become blank space below the newest output — the reader would open
        // showing nothing, on exactly the pane the user opened it to read.
        // Interior blank lines are kept: they are the paragraph breaks.
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        return lines
    }
}
