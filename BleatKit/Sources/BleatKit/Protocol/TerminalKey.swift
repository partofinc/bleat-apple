import Foundation

/// A key, as the bytes a terminal would send for it.
///
/// **Why keys rather than `terminal.scroll`.** Herdr's own scroll record moves
/// a pane's *host* scrollback, and an agent has none: measured 8 Sept 2026, a
/// pane running a full-screen program reports `max_offset_from_bottom: 0` and
/// `pane read --source recent` returns exactly the visible rows. The earlier
/// output is not in herdr at all — it is inside the program, which is drawing
/// its own viewport and scrolling it in response to keys. So the only way to
/// see it is to press the program's own keys, which is what these are.
///
/// Proved with `less` over 200 lines in a 30-row pane: sending a space moved
/// the visible rows from 1–29 to 59–87 while the host scrollback stayed 0.
///
/// The same argument reaches an agent's **dialogs**, which is what the arrows,
/// `escape` and `enter` are for. A blocked agent is one sitting at a question,
/// and `agent prompt` cannot answer it — herdr rejects a blocked agent with
/// `agent_blocked` *before sending any input*. Keys are the only thing that
/// moves such a dialog.
///
/// `TerminalCommand.bytes` carries them, because `text` cannot express an
/// escape sequence — a raw ESC inside a JSON string is not valid JSON, and the
/// host would ignore the record.
public enum TerminalKey: Sendable, CaseIterable {
    case left
    case up
    case down
    case right
    case escape
    case enter
    case pageUp
    case pageDown

    public var bytes: Data {
        switch self {
        // The xterm forms, which is what `TERM=xterm-256color` promises and
        // what herdr's panes advertise.
        //
        // **The arrows are the normal-mode forms, and that is measured rather
        // than assumed.** A program that turns on application cursor keys
        // (DECCKM) is sent `ESC O A` by a real terminal instead of `ESC [ A`,
        // and picking the wrong one gives a dialog that ignores every tap. Sent
        // over a real `terminal session control --takeover` against a Claude
        // Code trust dialog on 10 Sept 2026, `ESC [ B` moved its selection from
        // `No, exit` to `Yes, I trust this folder` — so the normal form is
        // accepted and is what ships. If some other agent kind ever refuses it,
        // this is the one place that changes.
        case .left: Data([0x1B, 0x5B, 0x44])            // ESC [ D
        case .up: Data([0x1B, 0x5B, 0x41])              // ESC [ A
        case .down: Data([0x1B, 0x5B, 0x42])            // ESC [ B
        case .right: Data([0x1B, 0x5B, 0x43])           // ESC [ C
        // A bare ESC. Ambiguous by construction — it is also the first byte of
        // every sequence above — so a program distinguishes the key from a
        // sequence by the pause that follows. Nothing here needs to help with
        // that: one tap is one write, and the next key is a human away.
        case .escape: Data([0x1B])
        // **Carriage return, not line feed.** Return sends CR on a pty; LF is
        // what the driver turns it into on the way out. A TUI reading raw
        // usually wants CR and an Ink-based one — which Claude Code is — treats
        // LF as a newline in the composer rather than a submit.
        case .enter: Data([0x0D])
        case .pageUp: Data([0x1B, 0x5B, 0x35, 0x7E])    // ESC [ 5 ~
        case .pageDown: Data([0x1B, 0x5B, 0x36, 0x7E])  // ESC [ 6 ~
        }
    }
}
