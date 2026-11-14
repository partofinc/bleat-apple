#if canImport(UIKit) && !os(watchOS)
import SwiftTerm
import UIKit

/// The terminal, which takes the keyboard only when it has been asked to.
///
/// This was `ReadOnlyTerminalView`, and it refused the keyboard unconditionally
/// because nothing could yet be done with a keystroke. Now something can, so
/// the refusal is a switch rather than a constant — but it is still a refusal by
/// default, and the default is what a pane being *watched* gets.
///
/// **`isUserInteractionEnabled = false` looks like the way to do this and is
/// the wrong tool**: it kills every gesture, including the selection and
/// long-press handling a rendered pane still wants. `TerminalView` raises the
/// keyboard by calling `becomeFirstResponder()` from its own tap and long-press
/// recognisers, so refusing first-responder status is what actually stops it —
/// and, now, allowing it is what lets the pane be typed into.
///
/// **The recognisers stay off the raising path anyway.** `acceptsKeyboard` is
/// set from an explicit toolbar button, not from a tap on the pane: a stray tap
/// on a surface whose whole job is to be dragged would otherwise start sending
/// keystrokes to a live agent. What this flag buys is the *ability* to become
/// first responder; `PaneTerminalController` decides when.
///
/// Note this view's **scrolling** is switched off separately, by
/// `PaneTerminalController` — see CLAUDE.md for why there is nothing to scroll.
final class PaneTerminalView: TerminalView {
    /// Whether the keyboard may be raised over this terminal at all.
    ///
    /// Dropping it while the keyboard is up puts it down, which is what makes
    /// releasing the pane also dismiss it — otherwise a keyboard would sit over
    /// a pane this screen no longer holds, dropping every keystroke in silence.
    var acceptsKeyboard = false {
        didSet {
            guard acceptsKeyboard != oldValue else { return }
            if !acceptsKeyboard, isFirstResponder { _ = resignFirstResponder() }
        }
    }

    override var canBecomeFirstResponder: Bool { acceptsKeyboard }

    /// Keeps SwiftTerm's own pans from taking the drag, except to extend a
    /// selection.
    ///
    /// SwiftTerm adds `UIPanGestureRecognizer`s to this view: one whenever a
    /// program asks for the mouse, to report drags as motion, and one when a
    /// selection starts (long press → Select, a double or triple tap), to
    /// extend it — which is not always taken away when the selection ends.
    /// Either wins every drag from `PaneScrollGesture`. The mouse one also
    /// reports nothing, since mouse reporting is off here
    /// (`PaneTerminalController`), so a pane under such a program simply
    /// stopped scrolling. Claude Code became one when it went full-screen
    /// (`?1049h`, `?1000h`/`?1002h`/`?1003h`, SGR; 2.1.325, found on a phone
    /// 14 Nov 2026).
    ///
    /// **Refused at the start, not kept from being added** (from review):
    /// SwiftTerm's `mouseModeChanged` and the paths that add a pan stay its
    /// own, so whatever else they do survives an update, and a pan added some
    /// other way is refused all the same. The mouse mode itself is left as the
    /// program set it, so the scroller in `TerminalHost` still encodes wheel
    /// clicks the way it asked. The scroll view's own pan is left to
    /// `isScrollEnabled`.
    override func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        if recognizer is UIPanGestureRecognizer, recognizer.view === self,
           recognizer !== panGestureRecognizer, !selectionActive {
            return false
        }
        // SwiftTerm's own single tap, while taps are clicks: with the
        // keyboard up it would also pop its menu by the cursor or follow a
        // link under the finger, on top of the click.
        if let tap = recognizer as? UITapGestureRecognizer, tap.view === self, tap !== clickRecognizer,
           tap.numberOfTapsRequired == 1, takesClicks {
            return false
        }
        return super.gestureRecognizerShouldBegin(recognizer)
    }

    // MARK: - Taps as clicks, full screen only

    /// Whether a tap is a click: the program is full screen (the alternate
    /// screen) and asked for presses and releases.
    ///
    /// **Decided by Ravil, 14 Nov 2026,** over the rule this pane had kept
    /// since 1.x — "a button, not a tap on the pane", so a stray touch could
    /// not click a live agent's dialog. Claude Code now runs full screen and
    /// is driven by its mouse there, and a pane that ignores taps is one
    /// that cannot be used like the Mac's. Kept from the rule: nothing
    /// outside full screen is clicked (a shell, or a program on the main
    /// screen, gets no press for a tap), taps never raise the keyboard, and
    /// mouse reporting itself stays off, so drags and hover report nothing.
    var takesClicks: Bool {
        let terminal = getTerminal()
        guard terminal.isCurrentBufferAlternate else { return false }
        switch terminal.mouseMode {
        case .vt200, .buttonEventTracking, .anyEvent: return true
        default: return false
        }
    }

    /// The tap that clicks. Installed by `enableClicks()`.
    private var clickRecognizer: UITapGestureRecognizer?

    /// Turns taps into clicks while `takesClicks`. Call once, after the view
    /// has set up its own recognisers.
    ///
    /// **It waits for SwiftTerm's double tap to fail**, a beat after the
    /// finger lifts, so a double tap still selects a word instead of
    /// clicking twice first.
    func enableClicks() {
        guard clickRecognizer == nil else { return }
        let tap = UITapGestureRecognizer(target: self, action: #selector(clicked(_:)))
        for other in gestureRecognizers ?? [] {
            if let double = other as? UITapGestureRecognizer, double.numberOfTapsRequired == 2 {
                tap.require(toFail: double)
            }
        }
        addGestureRecognizer(tap)
        clickRecognizer = tap
    }

    @objc private func clicked(_ tap: UITapGestureRecognizer) {
        guard tap.state == .ended else { return }
        click(at: tap.location(in: self))
    }

    /// Sends the program a left press and release on the cell under `point`,
    /// in this view's coordinates, if it takes clicks.
    func click(at point: CGPoint) {
        guard takesClicks, let cell = cell(at: point) else { return }
        let terminal = getTerminal()
        let press = terminal.encodeButton(button: 0, release: false, shift: false, meta: false, control: false)
        let release = terminal.encodeButton(button: 0, release: true, shift: false, meta: false, control: false)
        terminal.sendEvent(buttonFlags: press, x: cell.col, y: cell.row)
        terminal.sendEvent(buttonFlags: release, x: cell.col, y: cell.row)
    }

    /// The screen cell under `point`, zero-based. The bounds' origin is the
    /// scroll offset, so it is taken off first: rows count from the top of
    /// what is drawn, which on the alternate screen is the screen.
    func cell(at point: CGPoint) -> (col: Int, row: Int)? {
        let size = cellSize
        guard size.width > 0, size.height > 0 else { return nil }
        let terminal = getTerminal()
        let x = point.x - bounds.origin.x
        let y = point.y - bounds.origin.y
        guard x >= 0, y >= 0 else { return nil }
        let col = Int(x / size.width)
        let row = Int(y / size.height)
        guard col < terminal.cols, row < terminal.rows else { return nil }
        return (col, row)
    }

    /// The size SwiftTerm draws a cell at — its `computeFontDimensions`, line
    /// for line, which it keeps internal: the width of a `W`, and the font's
    /// ascent, descent and leading, rounded up. If SwiftTerm's line spacing
    /// is ever changed from its default of 1, this has to follow.
    var cellSize: CGSize {
        let width = "W".size(withAttributes: [.font: font]).width
        let ctFont = font as CTFont
        let height = ceil(CTFontGetAscent(ctFont) + CTFontGetDescent(ctFont) + CTFontGetLeading(ctFont))
        return CGSize(width: width, height: height)
    }

    /// Takes SwiftTerm's own accessory bar off the keyboard.
    ///
    /// It installs a `TerminalAccessory` — Esc, Tab, Ctrl, arrows — from its
    /// `setup()`, so without this there are two bars: SwiftTerm's riding the
    /// keyboard and `PaneKeyBar` above it. One set of keys, and it is ours,
    /// because ours is the one wired to the model and gated on the terminal
    /// being live.
    ///
    /// **Assigned, not overridden.** `TerminalView.inputAccessoryView` is a
    /// settable `public override var` backed by SwiftTerm's own storage, so a
    /// subclass override is refused outright ("cannot override mutable property
    /// with read-only property"). Writing to it is the supported route.
    func dropBuiltInAccessory() {
        guard inputAccessoryView != nil else { return }
        inputAccessoryView = nil
        reloadInputViews()
    }
}
#endif

// No `#Preview`: see `TerminalHost`. `PaneSurface` is where this screen is
// laid out for the canvas.
