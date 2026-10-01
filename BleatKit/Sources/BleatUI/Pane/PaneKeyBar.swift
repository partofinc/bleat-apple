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
            // **Disabled as a group, so the keyboard toggle stays live.** The
            // keys need a stream to go to; the toggle does not, and a keyboard
            // that cannot be dismissed because the stream is between opens is a
            // trap — half the screen gone with no way back.
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
            .disabled(!isLive)

            divider

            keyboardToggle
        }
        .padding(6)
        .glassEffect(in: .capsule)
        // **Capped, because these are key caps.** A physical Esc key does not
        // grow with the system's text size, and six of these have to fit across
        // the narrowest phone — at accessibility sizes `.body` outgrows the cap
        // vertically and `esc` truncates, on the one control that exists
        // *because* the drag gesture is unreachable by VoiceOver and Switch
        // Control. So the type is bounded and the caps grow to meet it rather
        // than clipping. The labels carry the meaning for anyone who needs it
        // larger, and they are read out in full whatever this is set to.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        // **Disabled, not hidden**, while the stream is between opens — taking
        // control reopens it, and so does the shrink this bar itself causes.
        // Hiding it would change the layout again, which is the loop described
        // in `PaneSurface`; `disabled` is drawn, not laid out, so it is safe.
        // A key pressed now would be dropped by `PaneModel.send` anyway, and a
        // dead tap that looks live is worse than a greyed one.
    }

    /// Raises and dismisses the system keyboard.
    ///
    /// **Here rather than in the toolbar**, which is where it started: on a
    /// device the two ended up at opposite edges of the screen, and this is a
    /// key row — the thing you reach for while typing belongs beside the keys
    /// you reach for while typing.
    ///
    /// **A button, not a tap on the pane.** Tapping the terminal to type is
    /// what a text field does and is wrong here: this surface's whole job is to
    /// be dragged, a drag misread as a tap is ordinary, and the cost is
    /// keystrokes into somebody's live agent. It is also the only version
    /// VoiceOver and Switch Control can reach.
    private var keyboardToggle: some View {
        Button {
            model.setWantsKeyboard(!model.wantsKeyboard)
        } label: {
            Image(systemName: model.wantsKeyboard ? "keyboard.chevron.compact.down" : "keyboard")
                .font(.body.weight(.semibold))
                .frame(minWidth: 44, minHeight: 38)
        }
        .buttonStyle(.plain)
        .contentShape(.rect)
        .accessibilityLabel(model.wantsKeyboard ? "Hide the keyboard" : "Show the keyboard")
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
                // is the horizontal one. `min`, not fixed: with the type size
                // bounded above, a larger setting grows the cap instead of
                // being cut off by it.
                .frame(minWidth: 44, minHeight: 38)
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
        model: PaneModel(previewing: .live),
        isActive: true
    )
}
#endif
#endif
