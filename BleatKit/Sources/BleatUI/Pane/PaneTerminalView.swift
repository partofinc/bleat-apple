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

    /// Takes SwiftTerm's own accessory bar off the keyboard.
    ///
    /// It installs a `TerminalAccessory` — Esc, Tab, Ctrl, arrows — from its
    /// `setup()`, so without this there are two bars: SwiftTerm's riding the
    /// keyboard and `PaneKeyBar` above it. One set of keys, and it is ours,
    /// because ours is the one wired to `PaneModel` and gated on holding the
    /// pane.
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
