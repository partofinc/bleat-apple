import Foundation

/// A line typed somewhere else and delivered to a pane whole: the text, then
/// Enter.
///
/// **What this is for.** Typing straight into a terminal from a phone means no
/// autocorrect, no dictation and no moving the cursor with a finger. Composed
/// in a text field instead, the line arrives as if it had been pasted at the
/// prompt and Return pressed.
///
/// **Measured against a scratch session on herdr 0.9.3, 1 Oct 2026**, over a
/// real `terminal session control --takeover`: zsh ran the line and Claude
/// Code submitted it as a prompt, both with the text and the carriage return
/// in one record and with them in two. Two is what is sent, so the Enter is
/// the same record `TerminalKey.enter` is everywhere else.
///
/// **One line, and that is a limit rather than a taste.** A newline inside the
/// text is Enter to whatever is reading: a shell runs the first line, and
/// Claude Code submits it and types the rest into the next prompt. Bracketed
/// paste would carry several lines as one — measured too, and Claude Code took
/// `ESC[200~ … ESC[201~` followed by a carriage return as a single prompt —
/// but only a program that has asked for it understands the markers, and
/// herdr does not pass that mode through in its frames (`?2004h` never
/// appears in them, at a zsh prompt that sets it). The phone cannot tell, so
/// line breaks become spaces.
public struct SubmittedLine: Sendable, Equatable {
    public let text: String

    /// Nil for text with nothing in it: an empty line is a bare Enter, which
    /// on an agent's dialog commits whatever is selected. That has its own
    /// key, and it should not be reachable by sending nothing.
    public init?(_ raw: String) {
        let line = raw
            .split(whereSeparator: \.isNewline)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return nil }
        text = line
    }

    /// The records to queue, in order.
    ///
    /// `.bytes` rather than `.text` for the line as well, so both travel the
    /// same way and nothing typed can be a problem for the JSON it rides in.
    public var commands: [TerminalCommand] {
        [.bytes(Data(text.utf8)), .bytes(TerminalKey.enter.bytes)]
    }
}
