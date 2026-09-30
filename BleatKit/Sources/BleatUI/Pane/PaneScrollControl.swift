#if canImport(UIKit)
import BleatKit
import SwiftUI

/// Scrolls a pane up and down, a handful of wheel notches a tap.
///
/// **Buttons as well as the drag, not instead of it.** `PaneScrollGesture`
/// handles the swipe; these stay because a drag is not reachable by VoiceOver
/// or Switch Control, and because a discoverable control beats a gesture
/// nothing advertises.
///
/// They send what the drag sends — `terminal.scroll`, which herdr applies to
/// its own history for a shell and hands to a full-screen program as wheel
/// events (see `PaneModel.scroll`). They used to send Page Up and Page Down,
/// which only a program that binds those keys would answer, and a shell's
/// history was out of reach entirely.
struct PaneScrollControl: View {
    let model: PaneModel

    var body: some View {
        VStack(spacing: 2) {
            button(.up, symbol: "chevron.up", label: "Scroll up")
            button(.down, symbol: "chevron.down", label: "Scroll down")
        }
        .padding(6)
        .glassEffect(in: .rect(cornerRadius: 14))
        .padding(.trailing, 8)
    }

    /// Five notches: fifteen lines of a shell's history, and about a third of a
    /// screen of Claude Code's — enough that a tap is visibly a step.
    private static let notches = 5

    private func button(_ direction: ScrollDirection, symbol: String, label: String) -> some View {
        Button {
            Task { await model.scroll(direction, notches: Self.notches) }
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
