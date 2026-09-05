#if canImport(UIKit)
import SwiftTerm

/// A terminal that will not take the keyboard.
///
/// `isUserInteractionEnabled = false` looks like the way to do this and is the
/// wrong tool: it also kills scrolling, and scrolling back through an agent's
/// output is most of the point of a read-only pane. `TerminalView` raises the
/// keyboard by calling `becomeFirstResponder()` from its own tap and
/// long-press recognisers, so refusing first-responder status is what actually
/// stops it — and it leaves the scroll view alone.
///
/// Without this, tapping the pane brings up a keyboard whose every keystroke
/// lands in a `send(source:data:)` that discards it. Phase 3 removes this type
/// along with the discarding.
final class ReadOnlyTerminalView: TerminalView {
    override var canBecomeFirstResponder: Bool { false }
}
#endif
