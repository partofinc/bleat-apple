#if canImport(UIKit) && !os(watchOS)
import BleatKit
import SwiftUI

/// The pane's accessory: somewhere to type, and the keys a phone has no key
/// for.
///
/// Two rows in one bubble. The bottom one is the keys a dialog is answered
/// with — arrows, `esc`, return — and the control that chooses what the top
/// one holds: a text field, or a strip of shortcuts. See `PaneAccessoryMode`.
///
/// **The key row exists because an agent's dialogs cannot be answered any
/// other way.** A blocked agent is one sitting at a question — a trust prompt,
/// a tool approval — and arrows, Esc and Enter are what move it.
///
/// **There are three ways to type, and each is for something.**
/// - The text field, for a line composed in comfort and sent whole.
/// - Straight into the pane — "Type in the Pane" in the menu — for what only
///   the program itself can do: a shell's completion, `vim`, anything read a
///   key at a time. The shortcut strip shows above the keyboard then, because
///   Tab is the point of typing there.
/// - The shortcut strip alone, for a key with no text around it.
///
/// **The bubble is the same height whatever it holds, and that is not
/// tidiness.** It sits in a safe-area bar, so its height is the terminal's
/// height, and `PaneTerminalController` reports that as the grid the pane is
/// `stty`'d to. A top row that changed height with the mode would resize the
/// pane on someone's Mac every time the menu was used. See `PaneSurface`.
///
/// **Glyphs, except `esc`.** Every key on the bottom row has a universally
/// drawn symbol apart from Escape, which is a word on every keyboard that has
/// one — an icon for it would be invented rather than recognised.
struct PaneKeyBar: View {
    let model: PaneModel
    /// Whether the terminal is the mode on screen. This bar stays mounted
    /// under the chat, and a field left focused there keeps a keyboard up
    /// over a transcript it cannot type into.
    let isActive: Bool

    /// Remembered between panes and launches: which one a person wants is a
    /// habit, not a property of the pane.
    @AppStorage("pane.accessoryMode") private var mode = PaneAccessoryMode.input
    /// Held here rather than by the field, so a line half typed survives a
    /// look at the shortcuts.
    @State private var draft = ""
    /// Whether the field has the keyboard. Plain state rather than
    /// `@FocusState`: the field is UIKit's — see `PaneLineField`.
    @State private var isComposing = false

    var body: some View {
        VStack(spacing: 6) {
            Group {
                switch shown {
                case .input: PaneInputField(model: model, draft: $draft, isFocused: $isComposing)
                case .shortcuts: PaneShortcutStrip(model: model)
                }
            }
            // **Fixed, and on the container rather than on either row**, so
            // the two cannot differ.
            .frame(height: Self.rowHeight)

            HStack(spacing: 2) {
                // **Disabled as a group, so the mode control stays live.** The
                // keys need a stream to go to; the control does not, and a
                // keyboard that cannot be dismissed because the stream is
                // between opens is a trap — half the screen gone with no way
                // back.
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

                modeControl
            }
        }
        .padding(8)
        .glassEffect(in: .rect(cornerRadius: 26))
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
        // **Capped, because these are key caps.** A physical Esc key does not
        // grow with the system's text size, and six of these have to fit across
        // the narrowest phone — at accessibility sizes `.body` outgrows the cap
        // vertically and `esc` truncates, on the one control that exists
        // *because* the drag gesture is unreachable by VoiceOver and Switch
        // Control. So the type is bounded and the caps grow to meet it rather
        // than clipping. The labels carry the meaning for anyone who needs it
        // larger, and they are read out in full whatever this is set to.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        // **One keyboard, one owner.** Focusing the field takes first
        // responder from the terminal by itself, but the terminal would take
        // it back on its next update while the model still said it wanted it.
        .onChange(of: isComposing) { _, composing in
            if composing { model.setWantsKeyboard(false) }
        }
        // `opacity(0)` does not resign anything — the same hazard
        // `PaneSurface` records for the terminal's own keyboard.
        .onChange(of: isActive) { _, active in
            if !active { isComposing = false }
        }
    }

    /// Both rows are this tall. See the note on the type.
    private static let rowHeight: CGFloat = 38

    /// What the top row holds right now.
    ///
    /// **The shortcuts, whenever the pane itself is being typed into.** The
    /// field would be a second place to type sitting above the keyboard of the
    /// first, and Tab and Ctrl-C are what that keyboard is missing. The chosen
    /// mode is left alone, so putting the keyboard away brings the field back.
    private var shown: PaneAccessoryMode {
        model.wantsKeyboard ? .shortcuts : mode
    }

    /// Whether a keyboard is up, for either way of typing.
    private var isTyping: Bool { isComposing || model.wantsKeyboard }

    /// Chooses what the top row holds — and, while a keyboard is up, puts it
    /// away instead.
    ///
    /// **Here rather than in the toolbar**, which is where the keyboard button
    /// started: on a device the two ended up at opposite edges of the screen,
    /// and this is a key row — the thing you reach for while typing belongs
    /// beside the keys you reach for while typing.
    ///
    /// **Typing in the pane is a menu item, not a tap on the pane.** Tapping
    /// the terminal to type is what a text field does and is wrong here: this
    /// surface's whole job is to be dragged, a drag misread as a tap is
    /// ordinary, and the cost is keystrokes into somebody's live agent. It is
    /// also the only version VoiceOver and Switch Control can reach.
    @ViewBuilder
    private var modeControl: some View {
        if isTyping {
            Button {
                isComposing = false
                model.setWantsKeyboard(false)
            } label: {
                modeCap { Image(systemName: "keyboard.chevron.compact.down") }
            }
            .buttonStyle(.plain)
            .contentShape(.rect)
            .accessibilityLabel("Hide the keyboard")
        } else {
            Menu {
                Picker("Accessory", selection: $mode) {
                    ForEach(PaneAccessoryMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.symbol).tag(mode)
                    }
                }
                Divider()
                Button("Type in the Pane", systemImage: "keyboard") {
                    model.setWantsKeyboard(true)
                }
            } label: {
                modeCap { Image(systemName: mode.symbol) }
            }
            .buttonStyle(.plain)
            .contentShape(.rect)
            .accessibilityLabel("Accessory mode")
            .accessibilityValue(mode.title)
        }
    }

    private func modeCap(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: Self.rowHeight)
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
                // Spread across the row, which is at least 44pt each on the
                // narrowest phone — the axis a finger misses on. `min` for the
                // height, not fixed: with the type size bounded above, a
                // larger setting grows the cap instead of being cut off by it.
                .frame(maxWidth: .infinity, minHeight: Self.rowHeight)
        }
        .buttonStyle(.plain)
        .contentShape(.rect)
        .accessibilityLabel(label)
    }
}

#if DEBUG
/// Over a live pane it holds, which is the only place it appears.
#Preview("Accessory", traits: .sampleData) {
    PaneSurface(
        model: PaneModel(previewing: .live),
        isActive: true
    )
}
#endif
#endif
