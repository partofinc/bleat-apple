#if canImport(UIKit) && !os(watchOS)
import BleatKit
import SwiftUI

/// Turns a drag on the terminal into wheel notches, the way a desktop terminal
/// turns a trackpad swipe into them — including the coast after a flick.
///
/// **This is still a request, not a scroll.** The stream carries one viewport
/// and no history, so there is no buffer under the finger to move. Each notch
/// asks the host to scroll and the host repaints: herdr moves its own history
/// for a shell, or hands a full-screen program — Claude Code, `less` — a wheel
/// event it answers itself. See `PaneModel.scroll`. A notch per row of travel
/// is what makes the content follow the finger, near enough, and
/// `ScrollMomentum` is what keeps it moving once the finger has gone.
///
/// Natural direction: pulling **down** brings earlier output down into view,
/// which is scrolling up — the same way a scroll view moves content with the
/// finger rather than against it.
///
struct PaneScrollGesture: ViewModifier {
    let model: PaneModel

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
    /// The coast after a flick, while it lasts.
    @State private var coast: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            // **Never behind an `if`.** A branch builds a `_ConditionalContent`,
            // and switching branch changes the structural identity of what it
            // wraps — here `TerminalHost`, whose controller would be torn down
            // and rebuilt, losing the rendered buffer. If this ever needs a
            // gate, use `.gesture(_:including:)`.
            .gesture(drag)
            .simultaneousGesture(touch)
            .onChange(of: isDragging) { _, dragging in
                if !dragging { spent = 0 }
            }
            .onDisappear { coast?.cancel() }
    }

    /// Finger travel per notch: the height of the one row a notch scrolls a
    /// shell by, so its history moves with the finger.
    ///
    /// **The terminal's own row height, not this view's height over its
    /// rows.** With the keyboard up the terminal keeps its full grid and
    /// slides under the navigation bar, so the visible height halves while the
    /// rows do not — and a step worked out from the two scrolled twice as fast
    /// as the finger for as long as the keyboard was showing.
    ///
    /// A full-screen program ignores `lines` and scrolls by its own amount —
    /// Claude Code accelerates — so there the match is only approximate. The
    /// fallback covers the moment before the terminal has laid out.
    private var step: CGFloat {
        max(8, model.rowHeight ?? 17)
    }

    private var drag: some Gesture {
        // Enough to not fire on a tap, small enough that a deliberate drag is
        // recognised immediately.
        DragGesture(minimumDistance: 16)
            .updating($isDragging) { _, state, _ in state = true }
            .onChanged { value in
                coast?.cancel()
                let moved = value.translation.height - spent
                let notches = min(Int(abs(moved) / step), Self.burst)
                guard notches > 0 else { return }
                let earlier = moved > 0
                spent += CGFloat(notches) * (earlier ? step : -step)
                Task { await model.scroll(earlier ? .up : .down, notches: notches) }
            }
            .onEnded { value in
                let left = value.translation.height - spent
                spent = 0
                // What the drag had not yet spent is carried over only when it
                // is less than a notch. More than that is the burst limit's
                // leftovers, and the coast is about to cover that ground anyway.
                //
                // **Only a vertical flick coasts.** A sideways swipe lifts off
                // with some vertical speed too — a few hundred points a second
                // is ordinary — and that alone would scroll a pane the finger
                // never moved.
                guard abs(value.velocity.height) > abs(value.velocity.width) else { return }
                startCoast(
                    velocity: value.velocity.height,
                    carrying: abs(left) < step ? left : 0
                )
            }
    }

    /// A finger put down stops the coast, the way it catches a scroll view.
    ///
    /// Its own gesture because `drag` only wakes after sixteen points of
    /// travel, and a flick that cannot be stopped by touching it is not
    /// momentum, it is a runaway. Simultaneous, so it claims nothing.
    private var touch: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in coast?.cancel() }
    }

    private func startCoast(velocity: CGFloat, carrying travel: CGFloat) {
        coast?.cancel()
        var momentum = ScrollMomentum(velocity: velocity, step: step, carrying: travel)
        guard !momentum.isFinished else { return }
        coast = Task {
            let clock = ContinuousClock()
            var last = clock.now
            // Only while there is a live stream to carry it: a coast that
            // outlasts the pane would be dropped a notch at a time anyway.
            while !momentum.isFinished, model.phase == .live {
                try? await Task.sleep(for: Self.tick)
                guard !Task.isCancelled else { return }
                let now = clock.now
                let notches = momentum.advance(by: now - last)
                last = now
                guard notches != 0 else { continue }
                // **Not awaited.** Waiting for the write would stretch the
                // coast out over however long a slow link takes — ten seconds
                // of scrolling after a two-second flick. Sent like the drag's
                // instead, and `PaneModel.scroll` drops what a slow link
                // cannot keep up with.
                let direction: ScrollDirection = notches > 0 ? .up : .down
                Task { await model.scroll(direction, notches: abs(notches)) }
            }
        }
    }

    /// How often the coast sends. A frame at 60Hz; the host cannot repaint
    /// faster than that to any purpose.
    private static let tick = Duration.milliseconds(16)

    /// The most notches one callback may send. A flick reports a large jump in
    /// one callback, and a wheel turned that fast is not something a program
    /// is written to expect; the rest of the travel is spent on later callbacks
    /// or left to the coast when the finger lifts.
    private static let burst = 6
}

extension View {
    /// Scrolls the pane on a drag.
    func paneScrollGesture(_ model: PaneModel) -> some View {
        modifier(PaneScrollGesture(model: model))
    }
}
#endif
