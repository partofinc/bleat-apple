#if os(macOS)   // see main.swift: the console tool is macOS-only
import BleatKit
import Darwin
import Foundation

/// Draws the pairing QR on the terminal's alternate screen.
///
/// The alternate screen is the point, not decoration. A QR rendered onto the
/// normal screen stays in **scrollback**, which iTerm2 persists to disk by
/// default and tmux keeps in history — so the enrollment key would outlive the
/// pairing in a place nobody thinks to clear. Drawing on the alternate screen
/// and restoring on exit leaves no trace in the buffer the user keeps.
enum PairScreen {
    static let enterAlternate = "\u{1B}[?1049h"
    static let leaveAlternate = "\u{1B}[?1049l"
    static let hideCursor = "\u{1B}[?25l"
    static let showCursor = "\u{1B}[?25h"
    static let clear = "\u{1B}[2J\u{1B}[H"

    /// Whether stdout is a terminal at all.
    ///
    /// `bleat pair > file` or a pipe gets none of this: escape sequences in a
    /// captured file are noise, and a QR made of block characters is not what
    /// a script wants.
    static var isInteractive: Bool { isatty(STDOUT_FILENO) == 1 }

    static func size() -> (columns: Int, rows: Int)? {
        var window = winsize()
        guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &window) == 0,
              window.ws_col > 0, window.ws_row > 0
        else { return nil }
        return (Int(window.ws_col), Int(window.ws_row))
    }

    /// Lines of chrome drawn around the QR, kept in one place so the fit check
    /// and the drawing cannot disagree.
    static let chromeRows = 6

    /// Whether a matrix will fit, given the terminal.
    static func fits(_ matrix: QRMatrix, in terminal: (columns: Int, rows: Int)) -> Bool {
        matrix.size <= terminal.columns && matrix.renderedRows + chromeRows <= terminal.rows
    }

    /// Reason a QR was not drawn, phrased for the user.
    static func tooSmallMessage(_ matrix: QRMatrix, _ terminal: (columns: Int, rows: Int)) -> String {
        "This window is \(terminal.columns)×\(terminal.rows); the code needs "
            + "\(matrix.size)×\(matrix.renderedRows + chromeRows). Resize and run again, "
            + "or send the link above to the phone and open it there."
    }

    static func write(_ text: String) {
        FileHandle.standardOutput.write(Data(text.utf8))
    }

    static func enter() {
        write(enterAlternate + hideCursor + clear)
    }

    /// Idempotent: leaving an alternate screen that was never entered is a
    /// no-op, which matters because this runs from the signal path too.
    static func leave() {
        write(showCursor + leaveAlternate)
    }

    static func draw(matrix: QRMatrix, title: String, subtitle: String, footer: String) {
        var out = clear + "  " + title + "\n"
        out += "  " + subtitle + "\n\n"
        for line in matrix.terminalLines() {
            out += line + "\n"
        }
        out += "\n  " + footer + "\n"
        write(out)
    }
}

#endif
