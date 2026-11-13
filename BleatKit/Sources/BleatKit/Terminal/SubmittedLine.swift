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
/// **Several lines go as one paste, where the program takes one.** A newline
/// is Enter to whatever reads it, so sent bare, a shell runs the first line
/// and Claude Code submits it and types the rest into the next prompt.
/// Bracketed paste (`ESC[200~ … ESC[201~`) carries several lines as one, but
/// only to a program that asked for it with `?2004h`. herdr hid that mode, and
/// 1.x sent line breaks as spaces. **hc passes it**: its first paint resets
/// every mode and sets the current ones, `?2004h` included, for zsh at a
/// prompt and for Claude Code (live, hc 0.1.20, 13 Nov 2026). Sent as a paste
/// then Enter, zsh ran both lines and Claude Code took them as one two-line
/// prompt. So the terminal on screen says whether the mode is on, and
/// `records(bracketedPaste:)` sends a paste when it is and spaces when not.
public struct SubmittedLine: Sendable, Equatable {
    /// What was typed, line breaks as `\n`, trimmed at both ends, with no
    /// control characters but tab.
    public let text: String

    /// Nil for text with nothing in it: an empty line is a bare Enter, which
    /// on an agent's dialog commits whatever is selected. That has its own
    /// key, and it should not be reachable by sending nothing.
    ///
    /// **Every line break is one** — CR, CRLF, vertical tab, form feed, NEL,
    /// U+2028, U+2029 (`Character.isNewline`) — as 1.x's split had it. Sent
    /// raw, form feed is Ctrl-L to zsh and vertical tab Ctrl-K (from review).
    ///
    /// **Control characters go**, ESC above all: typed or pasted text is text,
    /// and a key with no text has its own button. With no ESC left, no paste
    /// end marker can sit inside a paste, nor be rebuilt from pieces once
    /// another is removed — `a ESC[201 ESC[201~ ~rm` became `ESC[201~rm`
    /// under the strip-once this replaced (from review).
    public init?(_ raw: String) {
        var cleaned = ""
        for character in raw {
            if character.isNewline {
                cleaned.append("\n")
            } else if character == "\t" || !character.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
                cleaned.append(character)
            }
        }
        let text = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        self.text = text
    }

    public var isMultiline: Bool { text.contains("\n") }

    /// The lines as one, joined by spaces, for a program that reads a line at
    /// a time. Blank lines go.
    public var flattened: String {
        text.split(separator: "\n").joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    /// What goes to the terminal, in order: the text, then Enter.
    ///
    /// - Parameter bracketedPaste: whether the program has bracketed paste on
    ///   (`?2004h`). Only a multi-line text is wrapped: one line goes as it
    ///   always has, the way that was measured on both backends.
    ///
    /// **Line breaks inside the paste are LF**, kept after review: that is
    /// what zsh and Claude Code were measured taking, and what SwiftTerm's own
    /// paste sends (`iOSTerminalView.paste`, the text as it is). That paste
    /// is not reused here because it reads only `UIPasteboard`.
    public func records(bracketedPaste: Bool) -> [Data] {
        let enter = TerminalKey.enter.bytes
        guard isMultiline else { return [Data(text.utf8), enter] }
        guard bracketedPaste else { return [Data(flattened.utf8), enter] }
        return [Data((Self.pasteStart + text + Self.pasteEnd).utf8), enter]
    }

    static let pasteStart = "\u{1B}[200~"
    static let pasteEnd = "\u{1B}[201~"
}
