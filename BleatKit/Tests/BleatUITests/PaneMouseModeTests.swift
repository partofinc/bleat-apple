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
        controller.feedForTesting(claudeCodeModes)
        #expect(terminal.getTerminal().mouseMode != .off, "the modes took")
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
