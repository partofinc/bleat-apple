#if canImport(UIKit)
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
@Suite("A pane under a program that wants the mouse")
@MainActor
struct PaneMouseModeTests {
    /// Alternate screen, then normal, button-event and any-event tracking in
    /// SGR encoding: what Claude Code's paint leaves set.
    private let claudeCodeModes = Array("\u{1B}[?1049h\u{1B}[?1000h\u{1B}[?1002h\u{1B}[?1003h\u{1B}[?1006h".utf8)

    private func pans(on view: UIView) -> [UIPanGestureRecognizer] {
        (view.gestureRecognizers ?? []).compactMap { $0 as? UIPanGestureRecognizer }
    }

    @Test("SwiftTerm adds no pan of its own when the mouse is turned on")
    func noMousePan() {
        let view = PaneTerminalView(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        let before = pans(on: view).count
        view.feed(byteArray: claudeCodeModes[...])
        #expect(view.getTerminal().mouseMode != .off, "the modes took")
        #expect(pans(on: view).count == before)
    }

    @Test("wheel clicks still go out encoded as the program asked")
    func wheelStillEncoded() {
        let view = PaneTerminalView(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        view.feed(byteArray: claudeCodeModes[...])
        let engine = view.getTerminal()
        let flags = engine.encodeButton(button: 4, release: false, shift: false, meta: false, control: false)
        #expect(flags == 64, "SGR wheel up")
    }
}
#endif
