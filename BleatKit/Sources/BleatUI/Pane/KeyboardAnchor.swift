import Foundation

/// Where the terminal sits while the keyboard is up.
///
/// The terminal keeps its full height under the keyboard — resizing it would
/// resize the pane on the user's Mac — so only part of it shows, and the
/// question is which part. It used to be the bottom, always, which is right
/// for an agent: its input box is the last thing on its screen. It is wrong
/// for a shell, whose prompt is wherever its output has got to. On a pane with
/// three lines in it that is the top, and the keyboard slid the prompt off the
/// screen it was raised to type into.
///
/// So the terminal moves up **only as far as the last row with anything on
/// it**, and not at all when that row is already clear of the keyboard.
enum KeyboardAnchor {
    /// Rows kept in view beneath the last one in use, so the line being typed
    /// is not flush against the key bar.
    static let margin = 1

    /// The `y` of the terminal's frame: zero or negative.
    ///
    /// - Parameters:
    ///   - visible: the height left above the keyboard.
    ///   - terminal: the terminal's own, frozen, height.
    ///   - rowHeight: the height the terminal draws a row at. **Not
    ///     `terminal` over its row count**: the rows rarely fill the height
    ///     exactly, and spreading the leftover strip across them gives a
    ///     figure a little too large — so the offset would land between rows
    ///     and between pixels.
    ///   - lastRow: the lowest row in use — the cursor's, or the last with
    ///     content if that is lower. Zero-based.
    static func offset(
        visible: CGFloat, terminal: CGFloat, rowHeight: CGFloat, lastRow: Int
    ) -> CGFloat {
        // The most it can move: its bottom edge on the keyboard's top.
        let bottomAnchored = visible - terminal
        guard bottomAnchored < 0, rowHeight > 0 else { return 0 }
        let needed = min(CGFloat(lastRow + 1 + margin) * rowHeight, terminal)
        guard needed > visible else { return 0 }
        // In whole rows, so the row at the top edge is not cut through.
        let hidden = ((needed - visible) / rowHeight).rounded(.up)
        return max(bottomAnchored, -hidden * rowHeight)
    }
}
