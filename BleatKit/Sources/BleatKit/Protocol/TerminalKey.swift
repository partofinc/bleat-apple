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
/// `TerminalCommand.bytes` carries them, because `text` cannot express an
/// escape sequence — a raw ESC inside a JSON string is not valid JSON, and the
/// host would ignore the record.
public enum TerminalKey: Sendable, CaseIterable {
    case pageUp
    case pageDown

    public var bytes: Data {
        switch self {
        // The xterm forms, which is what `TERM=xterm-256color` promises and
        // what herdr's panes advertise.
        case .pageUp: Data([0x1B, 0x5B, 0x35, 0x7E])    // ESC [ 5 ~
        case .pageDown: Data([0x1B, 0x5B, 0x36, 0x7E])  // ESC [ 6 ~
        }
    }
}
