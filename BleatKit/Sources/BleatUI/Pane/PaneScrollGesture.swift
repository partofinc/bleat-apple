#if canImport(UIKit)
import BleatKit
import SwiftUI

/// Turns a drag on the terminal into the program's own page keys.
///
/// **This is a translation, not a scroll, and the difference is visible.**
/// There is no buffer under the finger to move: the pane's earlier output is
/// inside the program on the host, which redraws a whole screen when it is
/// sent Page Up. So a drag cannot track content continuously — it can only
/// decide *when* to ask for the next screen. Dragging is quantised into pages
/// for that reason, and it will always feel like paging rather than scrolling.
///
/// Natural direction: pulling **down** brings earlier output down into view,
/// which is Page Up — the same way a scroll view moves content with the
/// finger rather than against it.
///
/// Only while this screen owns the pane. Observing, there is nothing to send
/// the keys to, and a gesture that silently does nothing is worse than no
/// gesture — so the drag is not installed at all and the terminal keeps its
/// ordinary tap behaviour.
struct PaneScrollGesture: ViewModifier {
    let model: PaneModel

    /// How far the terminal is, so a page of dragging is a page of content.
    @State private var height: CGFloat = 0
    /// Translation already spent on keys within this one drag. A `DragGesture`
    /// reports a cumulative translation, so without this every callback past
    /// the threshold would fire again for the same movement.
    @State private var spent: CGFloat = 0

    func body(content: Content) -> some View {
        let sized = content.onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height = $0 }

        if model.control == .controlling {
            sized.gesture(drag)
        } else {
            sized
        }
    }

    /// Half the terminal, so a full-screen drag pages twice.
    ///
    /// A whole screen per page is the literal mapping and feels dead — the
    /// finger travels the entire pane before anything happens. Half is the
    /// compromise; the floor keeps it sane on a short pane or in landscape.
    private var step: CGFloat { max(120, height / 2) }

    private var drag: some Gesture {
        // Enough to not fire on a tap, small enough that a deliberate drag is
        // recognised immediately.
        DragGesture(minimumDistance: 16)
            .onChanged { value in
                let moved = value.translation.height - spent
                guard abs(moved) >= step else { return }
                // **One key per callback, not a loop.** A fast flick reports a
                // large jump, and paging it out all at once would send a burst
                // of keys the program renders as one long jump with nothing in
                // between. `onChanged` fires often enough that a fast drag
                // still pages fast.
                let earlier = moved > 0
                spent += earlier ? step : -step
                Task { await model.send(earlier ? .pageUp : .pageDown) }
            }
            .onEnded { _ in spent = 0 }
    }
}

extension View {
    /// Pages the pane's program when this screen owns its input.
    func paneScrollGesture(_ model: PaneModel) -> some View {
        modifier(PaneScrollGesture(model: model))
    }
}
#endif
