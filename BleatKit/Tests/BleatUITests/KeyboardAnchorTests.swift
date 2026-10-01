import Foundation
import Testing
@testable import BleatUI

/// Which part of a terminal shows above the keyboard. Arithmetic, so tested as
/// arithmetic; `PaneGeometryTests` covers the controller that feeds it.
@Suite("Keyboard anchor")
struct KeyboardAnchorTests {
    // 40 rows of 10 points, with 200 points left above the keyboard: 20 rows.
    private func offset(lastRow: Int, visible: CGFloat = 200) -> CGFloat {
        KeyboardAnchor.offset(visible: visible, terminal: 400, rowHeight: 10, lastRow: lastRow)
    }

    /// The bug: a shell with a few lines in it was slid off the top.
    @Test("a prompt near the top does not move")
    func topStays() {
        #expect(offset(lastRow: 0) == 0)
        #expect(offset(lastRow: 2) == 0)
        // The last row that fits with its margin beneath it.
        #expect(offset(lastRow: 18) == 0)
    }

    @Test("a prompt under the keyboard is lifted just clear of it")
    func liftsOnlyAsFarAsNeeded() {
        // Row 19 fits, its margin row does not: one row up.
        #expect(offset(lastRow: 19) == -10)
        #expect(offset(lastRow: 29) == -110)
    }

    /// What an agent's screen gets, and what every pane got before.
    @Test("a screen drawn to the bottom is pinned by its bottom edge")
    func bottomIsTheLimit() {
        #expect(offset(lastRow: 39) == -200)
        #expect(offset(lastRow: 38) == -200)
        // Nonsense from the emulator must not push it past the keyboard.
        #expect(offset(lastRow: 400) == -200)
    }

    /// A row at the top edge is hidden whole or shown whole.
    @Test("it moves in whole rows")
    func wholeRows() {
        let y = offset(lastRow: 25, visible: 203)
        #expect(y.truncatingRemainder(dividingBy: 10) == 0)
        #expect(y == -70)
    }

    @Test("with no keyboard in the way it does not move")
    func nothingToAvoid() {
        #expect(offset(lastRow: 39, visible: 400) == 0)
        #expect(offset(lastRow: 39, visible: 500) == 0)
        #expect(KeyboardAnchor.offset(visible: 200, terminal: 400, rowHeight: 0, lastRow: 3) == 0)
    }

    /// **The rows rarely fill the height exactly.** A 407-point terminal of
    /// 10-point rows holds 40 with a strip left over; the offset is still in
    /// those 10-point rows, not in 407/40ths.
    @Test("a strip left under the last row does not skew the rows")
    func leftoverStrip() {
        let y = KeyboardAnchor.offset(visible: 200, terminal: 407, rowHeight: 10, lastRow: 25)
        #expect(y == -70)
        // And the limit is the real bottom edge, strip included.
        #expect(KeyboardAnchor.offset(visible: 200, terminal: 407, rowHeight: 10, lastRow: 39) == -207)
    }
}
