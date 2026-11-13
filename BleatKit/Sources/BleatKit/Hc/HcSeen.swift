import Foundation

/// `herdr.seen`, written as herdr-app's `docs/labels.md` says a client that
/// shows an agent writes it — decided by Ravil, 13 Nov 2026, over keeping the
/// phone read-only: reading an agent's result on the phone is reading it, so
/// it stops being "done" on the Mac too.
///
/// The convention (read 13 Nov 2026):
/// - While a person is looking at a terminal, write `herdr.seen=<turn>`;
///   only to raise it, and also when it is missing, so terminals started
///   elsewhere join.
/// - **Once per turn while it stays on screen**, not on every update, so a
///   "mark unread" from another client is not overruled by a screen nobody
///   is reading. Looking again later raises it again: a new look is a new
///   `HcSeen`.
/// - Last writer wins; hc never interprets the label.
///
/// One per look at one terminal. What counts as looking is the screen's call
/// (`HcPaneModel`): on show, attached, and the app in front.
public struct HcSeen: Sendable, Equatable {
    /// The turn this look last wrote.
    private var written: Int?

    public init() {}

    /// The turn to write for `terminal` now, if any; recorded as written.
    public mutating func turnToWrite(for terminal: HcTerminal) -> Int? {
        guard terminal.isLive, let turn = terminal.turn, turn >= 0 else { return nil }
        if let seen = terminal.seenTurn, seen >= turn { return nil }
        guard written != turn else { return nil }
        written = turn
        return turn
    }

    /// The write of `turn` failed: the next update tries it again.
    public mutating func failed(_ turn: Int) {
        if written == turn { written = nil }
    }

    /// The label the core is asked to set.
    public static let label = "herdr.seen"

    /// `terminal.label`'s params for writing `turn` on `address`.
    public static func params(address: String, turn: Int) -> [String: HcJSON] {
        ["terminal": .string(address), "labels": .object([label: .string(String(turn))])]
    }
}
