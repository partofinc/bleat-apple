#if canImport(UIKit)
import Foundation
import SwiftTerm
import Testing
import UIKit
@testable import BleatUI

/// Why the terminal has no scrollback, settled inside SwiftTerm rather than
/// argued about.
///
/// The question keeps coming back in the form "SwiftTerm is a real xterm
/// emulator, so surely there is a scrollback setting" — and the premise is
/// right. There is, it is on by default, and it works. `plainLinesDoScroll`
/// below builds the same view the app builds, feeds it ordinary lines, and it
/// scrolls.
///
/// What it is never given is lines. `Fixtures/terminal-observe-scrolled.ndjson`
/// is a real capture from a pane that had **genuinely scrolled 200 lines** —
/// `seq 1 200` through a 30-row pane, with 172 rows of scrollback recorded on
/// the host — and every frame in it is a repaint of the viewport with **zero
/// newlines**. Herdr renders its own buffer and ships absolute cursor
/// positioning, so nothing is ever pushed off the top of the emulator and its
/// scrollback stays empty by construction.
///
/// So there is nothing to enable. This test exists so that the next person to
/// have the idea sees the measurement instead of re-deriving it.
@Suite("The terminal's scrollback", .serialized)
@MainActor
struct ScrollbackTests {

    /// `Fixtures/` lives at the package root; `BleatKitTests` has its own copy
    /// of this and neither target can see the other's helpers.
    private func fixture(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)      // Tests/BleatUITests/…
            .deletingLastPathComponent()               // Tests/BleatUITests
            .deletingLastPathComponent()               // Tests
            .deletingLastPathComponent()               // BleatKit/
            .appendingPathComponent("Fixtures/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func frames(_ ndjson: String) -> [Data] {
        ndjson.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["type"] as? String == "terminal.frame",
                  let encoded = object["bytes"] as? String
            else { return nil }
            return Data(base64Encoded: encoded)
        }
    }

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

    /// **And the answer.** The same view, fed a real pane's stream, cannot
    /// scroll — because the stream contains no lines to scroll.
    @Test("a real pane stream leaves it with nothing to scroll")
    func herdrFramesDoNotScroll() throws {
        let captured = frames(try fixture("terminal-observe-scrolled.ndjson"))
        #expect(!captured.isEmpty, "the fixture decoded to no frames")

        // The load-bearing property of the capture, asserted rather than
        // assumed: herdr paints in place. If a future herdr ever did send
        // newlines this would fail, and the app could then simply stop paging
        // by hand.
        let newlines = captured.reduce(0) { $0 + $1.filter { $0 == 0x0A }.count }
        #expect(newlines == 0, "the stream carried \(newlines) newlines")

        let view = view()
        let terminal = view.getTerminal()
        for frame in captured { terminal.feed(byteArray: [UInt8](frame)) }

        #expect(!view.canScroll, "there is scrollback after all — paging by hand is unnecessary")
        #expect(terminal.getTopVisibleRow() == 0)
        // Not the alternate screen doing it, either: the emulator is on its
        // normal buffer and simply has one screen in it.
        #expect(!terminal.isCurrentBufferAlternate)
    }
}
#endif
