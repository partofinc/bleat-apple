#if canImport(UIKit)
import BleatKit
import SwiftUI

/// Turns a drag on the terminal into wheel notches, the way a desktop terminal
/// turns a trackpad swipe into them.
///
/// **This is still a request, not a scroll.** The stream carries one viewport
/// and no history, so there is no buffer under the finger to move. Each notch
/// asks the host to scroll and the host repaints: herdr moves its own history
/// for a shell, or hands a full-screen program — Claude Code, `less` — a wheel
/// event it answers itself. See `PaneModel.scroll`. What a notch per few rows
/// of travel buys over the page keys this replaced is that the content follows
/// the finger, near enough, instead of jumping a screen at a time.
///
/// Natural direction: pulling **down** brings earlier output down into view,
/// which is scrolling up — the same way a scroll view moves content with the
/// finger rather than against it.
///
struct PaneScrollGesture: ViewModifier {
    let model: PaneModel

    /// How tall the terminal is, so a notch can be sized to its rows.
    @State private var height: CGFloat = 0
    /// Translation already spent on notches within this one drag. A
    /// `DragGesture` reports a cumulative translation, so without this every
    /// callback past the threshold would fire again for the same movement.
    @State private var spent: CGFloat = 0
    /// Whether a drag is in flight.
    ///
    /// `@GestureState` for one reason: it resets itself when the gesture ends
    /// **or is cancelled**, and `onEnded` does not run on a cancellation. Left
    /// to `onEnded` alone, a drag interrupted by another recogniser leaves
    /// `spent` behind, and the next drag is measured against travel that
    /// already happened.
    @GestureState private var isDragging = false

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height = $0 }
            // **Never behind an `if`.** A branch builds a `_ConditionalContent`,
            // and switching branch changes the structural identity of what it
            // wraps — here `TerminalHost`, whose controller would be torn down
            // and rebuilt, losing the rendered buffer. If this ever needs a
            // gate, use `.gesture(_:including:)`.
            .gesture(drag)
            .onChange(of: isDragging) { _, dragging in
                if !dragging { spent = 0 }
            }
    }

    /// Finger travel per notch: the height of the three rows a notch scrolls a
    /// shell by, so its history moves with the finger.
    ///
    /// A full-screen program ignores `lines` and scrolls by its own amount —
    /// Claude Code accelerates — so there the match is only approximate. The
    /// floor keeps a pane with no known grid from firing on every point.
    private var step: CGFloat {
        guard let rows = model.grid?.rows, rows > 0, height > 0 else { return 36 }
        return max(12, height / CGFloat(rows) * 3)
    }

    private var drag: some Gesture {
        // Enough to not fire on a tap, small enough that a deliberate drag is
        // recognised immediately.
        DragGesture(minimumDistance: 16)
            .updating($isDragging) { _, state, _ in state = true }
            .onChanged { value in
                let moved = value.translation.height - spent
                let notches = min(Int(abs(moved) / step), Self.burst)
                guard notches > 0 else { return }
                let earlier = moved > 0
                spent += CGFloat(notches) * (earlier ? step : -step)
                Task { await model.scroll(earlier ? .up : .down, notches: notches) }
            }
            .onEnded { _ in spent = 0 }
    }

    /// The most notches one callback may send. A flick reports a large jump in
    /// one callback, and a wheel turned that fast is not something a program
    /// is written to expect; the rest of the travel is spent on later callbacks
    /// or dropped when the finger lifts.
    private static let burst = 6
}

extension View {
    /// Scrolls the pane on a drag.
    func paneScrollGesture(_ model: PaneModel) -> some View {
        modifier(PaneScrollGesture(model: model))
    }
}
#endif
