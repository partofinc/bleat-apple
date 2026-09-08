#if canImport(UIKit)
import BleatKit
import SwiftUI

/// Pages a pane's program up and down.
///
/// **Buttons rather than a swipe, for now.** `TerminalView` is a
/// `UIScrollView` and already claims vertical drags for a buffer that is
/// always empty; a gesture fighting it for the same drag is a worse first
/// version than two controls that plainly work. The swipe can come once these
/// have proved the keys are right for the program in the pane.
///
/// **These are the program's keys, not a scrollbar.** There is no host
/// scrollback behind an agent's pane to move through — herdr reports
/// `max_offset_from_bottom: 0` for every one of them. What earlier output
/// exists is inside the program, which redraws when it is sent Page Up. So
/// this is a keyboard with two keys on it, and whether it does anything at all
/// depends on the program: `less` and every full-screen pager answer, and one
/// that ignores Page Up will simply not move.
struct PaneScrollControl: View {
    let model: PaneModel

    var body: some View {
        VStack(spacing: 2) {
            key(.pageUp, symbol: "chevron.up", label: "Page up")
            key(.pageDown, symbol: "chevron.down", label: "Page down")
        }
        .padding(6)
        .glassEffect(in: .rect(cornerRadius: 14))
        .padding(.trailing, 8)
    }

    private func key(_ key: TerminalKey, symbol: String, label: String) -> some View {
        Button {
            Task { await model.send(key) }
        } label: {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 40)
        }
        .buttonStyle(.plain)
        .contentShape(.rect)
        .accessibilityLabel(label)
    }
}

#if DEBUG
/// Over a live pane, which is the only place it appears.
#Preview("Scroll control", traits: .sampleData) {
    PaneSurface(
        model: PaneModel(previewing: .live, control: .controlling),
        isActive: true
    )
}
#endif
#endif
