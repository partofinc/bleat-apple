#if canImport(UIKit)
import Foundation
import SwiftTerm
import Testing
import UIKit
@testable import BleatUI

/// The terminal's own scrollback, which Bleat 2's scroller relies on for a
/// shell: hc's attach paints history first (`history`), and those lines are
/// pushed into SwiftTerm's buffer, so `scrollUp`/`scrollDown` have something
/// to move. `plainLinesDoScroll` builds the same view the app builds, feeds it
/// ordinary lines, and it scrolls.
///
/// (1.x measured the opposite under herdr, which shipped one viewport of
/// absolute positioning and never a newline; that test went with the herdr
/// backend. The record is in `docs/pane-view.md`.)
@Suite("The terminal's scrollback", .serialized)
@MainActor
struct ScrollbackTests {

    private func view() -> TerminalView {
        TerminalView(frame: CGRect(x: 0, y: 0, width: 900, height: 500))
    }

    /// **The premise, confirmed.** Nothing is configured here — this is the
    /// same `TerminalView` the app mounts, with SwiftTerm's default 500-line
    /// scrollback — and ordinary output fills it.
    @Test("SwiftTerm scrolls by default, given lines")
    func plainLinesDoScroll() {
        let view = view()
        let terminal = view.getTerminal()
        for i in 1...200 { terminal.feed(text: "line \(i)\r\n") }

        #expect(view.canScroll, "SwiftTerm's own scrollback did not fill for ordinary output")
        #expect(terminal.getTopVisibleRow() > 0)
    }
}
#endif
