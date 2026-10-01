#if canImport(UIKit)
import BleatKit
import SwiftUI

/// Where a line is composed before it goes to the pane.
///
/// A real text field, so what the system keyboard does works — autocorrect,
/// dictation, the cursor under a finger — none of which a terminal offers.
/// Nothing reaches the pane until it is sent, and then the whole line goes at
/// once with Enter after it. See `SubmittedLine`, and `PaneLineField` for why
/// the field itself is UIKit's.
///
/// **One line, at a fixed height.** This row is in a safe-area bar, and the
/// bar's height is the terminal's height, which is the pane's size on
/// someone's Mac — a field that grew with its text would resize their pane as
/// the user typed.
struct PaneInputField: View {
    let model: PaneModel
    @Binding var draft: String
    @Binding var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            PaneLineField(
                placeholder: "Type a line to send",
                text: $draft,
                isFocused: $isFocused,
                onSubmit: send
            )
            .padding(.horizontal, 12)
            .frame(maxHeight: .infinity)
            .background(.fill.tertiary, in: .capsule)

            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title)
                    .frame(maxHeight: .infinity)
            }
            .buttonStyle(.plain)
            .foregroundStyle(canSend ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            .disabled(!canSend)
            .accessibilityLabel("Send")
        }
    }

    private var line: SubmittedLine? { SubmittedLine(draft) }

    /// Only with something to send and a stream to send it on. The field
    /// itself is never disabled: that would drop the keyboard every time the
    /// stream reopened, and take the half-typed line's cursor with it.
    private var canSend: Bool { line != nil && model.phase == .live }

    private func send() {
        // **Kept when there is plainly nowhere to send it**, since the model
        // drops input with no stream. That is as far as the promise goes: the
        // line is queued, not acknowledged, so a stream that reopens or dies
        // in the moment between here and the write still loses it — or types
        // it without its Enter. Rare, visible in the pane, and not something
        // this layer can know.
        guard canSend, let line else { return }
        draft = ""
        Task { await model.submit(line) }
    }
}

// No `#Preview` of its own: `PaneKeyBar` previews it in place.
#endif
