#if canImport(UIKit)
import BleatKit
import SwiftUI

/// The keys a pane's program needs to answer a question, as a bar under it.
///
/// **This exists because an agent's dialogs cannot be answered any other way.**
/// A blocked agent is one sitting at a question — a trust prompt, a tool
/// approval — and `herdr agent prompt` refuses a blocked agent with
/// `agent_blocked` *before it sends anything*, so the prompt composer is
/// structurally unable to move one. Arrows, Esc and Enter are what move it.
///
/// **Deliberately six keys and no more.** This is not a keyboard: there is no
/// text entry here, because typing is `agent prompt`'s job and that command
/// handles bracketed paste and submission properly. What is missing from the
/// phone is only the *navigation* of a dialog that is already on screen.
///
/// **Glyphs, except `esc`.** Every one of these is a key with a universally
/// drawn symbol apart from Escape, which is a word on every keyboard that has
/// one — an icon for it would be invented rather than recognised.
struct PaneKeyBar: View {
    let model: PaneModel

    var body: some View {
        HStack(spacing: 2) {
            key(.left, symbol: "arrow.left", label: "Left arrow")
            key(.up, symbol: "arrow.up", label: "Up arrow")
            key(.down, symbol: "arrow.down", label: "Down arrow")
            key(.right, symbol: "arrow.right", label: "Right arrow")

            divider

            // The one word. `esc` lower-cased is how it is printed on a key.
            key(.escape, label: "Escape") {
                Text("esc")
                    .font(.caption.weight(.bold))
            }

            divider

            key(.enter, symbol: "return", label: "Enter")
        }
        .padding(6)
        .glassEffect(in: .capsule)
        // **Disabled, not hidden**, while the stream is between opens — taking
        // control reopens it, and so does the shrink this bar itself causes.
        // Hiding it would change the layout again, which is the loop described
        // in `PaneSurface`; `disabled` is drawn, not laid out, so it is safe.
        // A key pressed now would be dropped by `PaneModel.send` anyway, and a
        // dead tap that looks live is worse than a greyed one.
        .disabled(!isLive)
    }

    private var isLive: Bool {
        if case .live = model.phase { return true }
        return false
    }

    /// Separates the arrows from the two keys that *commit* something. Enter on
    /// a dialog is not undoable — on Claude Code's trust prompt the default
    /// selection is `No, exit`, which ends the agent — so it is worth a gap
    /// rather than sitting flush against the arrow the user was just tapping.
    private var divider: some View {
        Divider().frame(height: 22)
    }

    private func key(
        _ key: TerminalKey,
        symbol: String,
        label: String
    ) -> some View {
        self.key(key, label: label) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
        }
    }

    private func key(
        _ key: TerminalKey,
        label: String,
        @ViewBuilder cap: () -> some View
    ) -> some View {
        Button {
            Task { await model.send(key) }
        } label: {
            cap()
                // 44pt on the axis a finger misses on, which for a row of keys
                // is the horizontal one.
                .frame(width: 44, height: 38)
        }
        .buttonStyle(.plain)
        .contentShape(.rect)
        .accessibilityLabel(label)
    }
}

#if DEBUG
/// Over a live pane it holds, which is the only place it appears.
#Preview("Key bar", traits: .sampleData) {
    PaneSurface(
        model: PaneModel(previewing: .live, control: .controlling),
        isActive: true
    )
}
#endif
#endif
