#if canImport(UIKit) && !os(watchOS)
import SwiftTerm
import Testing
import UIKit
@testable import BleatUI

/// A program turning the mouse on must not take the drag from the pane.
///
/// **Found on a phone, 14 Nov 2026:** Claude Code stopped scrolling. It now
/// runs full-screen and asks for the mouse, and SwiftTerm answers any mouse
/// mode by adding a `UIPanGestureRecognizer` of its own to the terminal. That
/// recogniser won every drag from `PaneScrollGesture` and then did nothing
/// with it, since this app turns mouse reporting off. The modes are the ones
/// Claude Code 2.1.325 set, captured from a scratch terminal's attach.
///
/// The terminal is the controller's, laid out in a window after its
/// `viewDidLoad`, as on screen (from review).
@Suite("A pane under a program that wants the mouse", .serialized)
@MainActor
struct PaneMouseModeTests {
    /// Alternate screen, then normal, button-event and any-event tracking in
    /// SGR encoding: what Claude Code's paint leaves set.
    private let claudeCodeModes = Data("\u{1B}[?1049h\u{1B}[?1000h\u{1B}[?1002h\u{1B}[?1003h\u{1B}[?1006h".utf8)

    private final class Sent {
        var bytes = Data()
    }

    private func pane() throws -> (PaneTerminalView, Sent, UIWindow) {
        try pane(modes: claudeCodeModes)
    }

    private func pane(modes: Data) throws -> (PaneTerminalView, Sent, UIWindow) {
        let controller = PaneTerminalController()
        let sent = Sent()
        var ready: TerminalView?
        controller.onReady = { ready = $0 }
        controller.onInput = { sent.bytes.append($0) }
        let window = TestWindow.make(frame: CGRect(x: 0, y: 0, width: 393, height: 700))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        let terminal = try #require(ready as? PaneTerminalView, "the controller hands over its terminal")
        controller.feedForTesting(modes)
        return (terminal, sent, window)
    }

    /// SwiftTerm's own pans: on the terminal, not the scroll view's.
    private func swiftTermPans(on terminal: PaneTerminalView) -> [UIPanGestureRecognizer] {
        (terminal.gestureRecognizers ?? [])
            .compactMap { $0 as? UIPanGestureRecognizer }
            .filter { $0 !== terminal.panGestureRecognizer }
    }

    @Test("SwiftTerm's pans may not start, so the drag is the pane's to scroll")
    func pansRefused() throws {
        let (terminal, _, window) = try pane()
        defer { window.isHidden = true }
        #expect(terminal.getTerminal().mouseMode != .off, "the modes took")
        let pans = swiftTermPans(on: terminal)
        #expect(!pans.isEmpty, "SwiftTerm added its mouse pan, which is what is refused")
        for pan in pans {
            #expect(!terminal.gestureRecognizerShouldBegin(pan))
        }
    }

    @Test("while a selection is up, its drag still extends it")
    func selectionKeepsItsPan() throws {
        let (terminal, _, window) = try pane()
        defer { window.isHidden = true }
        terminal.selectAll()
        #expect(terminal.selectionActive)
        for pan in swiftTermPans(on: terminal) {
            #expect(terminal.gestureRecognizerShouldBegin(pan))
        }
        terminal.selectNone()
        for pan in swiftTermPans(on: terminal) {
            #expect(!terminal.gestureRecognizerShouldBegin(pan))
        }
    }

    // MARK: Taps, full screen only (decided by Ravil, 14 Nov 2026)

    /// The middle of a cell, in the terminal's own coordinates.
    private func point(col: Int, row: Int, on terminal: PaneTerminalView) -> CGPoint {
        let size = terminal.cellSize
        return CGPoint(
            x: terminal.bounds.origin.x + (CGFloat(col) + 0.5) * size.width,
            y: terminal.bounds.origin.y + (CGFloat(row) + 0.5) * size.height
        )
    }

    @Test("full screen, a tap is a left press and release on the tapped cell, in SGR")
    func tapClicks() throws {
        let (terminal, sent, window) = try pane()
        defer { window.isHidden = true }
        #expect(terminal.takesClicks)
        terminal.click(at: point(col: 7, row: 3, on: terminal))
        #expect(String(decoding: sent.bytes, as: UTF8.self) == "\u{1B}[<0;8;4M\u{1B}[<0;8;4m")
    }

    @Test("a tap off the grid clicks nothing")
    func tapOffGrid() throws {
        let (terminal, sent, window) = try pane()
        defer { window.isHidden = true }
        let cols = terminal.getTerminal().cols
        terminal.click(at: point(col: cols + 2, row: 0, on: terminal))
        terminal.click(at: CGPoint(x: -4, y: terminal.bounds.origin.y + 4))
        #expect(sent.bytes.isEmpty)
    }

    @Test("not full screen, a tap clicks nothing", arguments: [
        // A shell: neither.
        "",
        // Mouse asked for on the main screen: Claude Code not full screen.
        "\u{1B}[?1000h\u{1B}[?1006h",
        // Full screen without the mouse: less, vim.
        "\u{1B}[?1049h",
    ])
    func tapOutsideFullScreen(modes: String) throws {
        let (terminal, sent, window) = try pane(modes: Data(modes.utf8))
        defer { window.isHidden = true }
        #expect(!terminal.takesClicks)
        terminal.click(at: point(col: 2, row: 2, on: terminal))
        #expect(sent.bytes.isEmpty)
    }

    @Test("while taps click, SwiftTerm's own single tap may not start; otherwise it may")
    func swiftTermTapRefused() throws {
        let (terminal, _, window) = try pane()
        defer { window.isHidden = true }
        let taps = (terminal.gestureRecognizers ?? []).compactMap { $0 as? UITapGestureRecognizer }
        let singles = taps.filter { $0.numberOfTapsRequired == 1 }
        // SwiftTerm's single tap and ours.
        #expect(singles.count == 2)
        let refused = singles.filter { !terminal.gestureRecognizerShouldBegin($0) }
        #expect(refused.count == 1, "SwiftTerm's, not ours")
        let doubles = taps.filter { $0.numberOfTapsRequired == 2 }
        #expect(doubles.allSatisfy { terminal.gestureRecognizerShouldBegin($0) }, "a double tap still selects")

        let (shell, _, shellWindow) = try pane(modes: Data())
        defer { shellWindow.isHidden = true }
        let shellSingles = (shell.gestureRecognizers ?? []).compactMap { $0 as? UITapGestureRecognizer }
            .filter { $0.numberOfTapsRequired == 1 }
        #expect(shellSingles.allSatisfy { shell.gestureRecognizerShouldBegin($0) })
    }

    @Test("a wheel click goes out as SGR, the encoding Claude Code asked for")
    func wheelSentAsSGR() throws {
        let (terminal, sent, window) = try pane()
        defer { window.isHidden = true }
        // What `TerminalHost`'s scroller does for a notch up.
        let engine = terminal.getTerminal()
        let flags = engine.encodeButton(button: 4, release: false, shift: false, meta: false, control: false)
        engine.sendEvent(buttonFlags: flags, x: 10, y: 5)
        #expect(String(decoding: sent.bytes, as: UTF8.self) == "\u{1B}[<64;11;6M")
    }
}
#endif
