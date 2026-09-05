#if canImport(UIKit)
import SwiftTerm

/// A terminal that will not take the keyboard.
///
/// `isUserInteractionEnabled = false` looks like the way to do this and is the
/// wrong tool: it kills every gesture, including the selection and long-press
/// handling that a rendered pane still wants. `TerminalView` raises the
/// keyboard by calling `becomeFirstResponder()` from its own tap and
/// long-press recognisers, so refusing first-responder status is what actually
/// stops it.
///
/// Note this view's **scrolling** is switched off separately, by
/// `PaneTerminalController`: the terminal is sized to the whole pane and panned
/// by an outer scroll view, and two scroll views competing for one drag make
/// the pane unmovable. That costs the local scrollback this comment used to
/// cite as the reason for the choice above — see CLAUDE.md, where the
/// trade-off and its host-side replacement are recorded.
///
/// Without this, tapping the pane brings up a keyboard whose every keystroke
/// lands in a `send(source:data:)` that discards it. Phase 3 removes this type
/// along with the discarding.
final class ReadOnlyTerminalView: TerminalView {
    override var canBecomeFirstResponder: Bool { false }
}
#endif
