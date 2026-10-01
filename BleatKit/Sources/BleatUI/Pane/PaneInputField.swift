#if canImport(UIKit)
import BleatKit
import SwiftUI

/// Where a line is composed before it goes to the pane.
///
/// An ordinary text field, so everything the system keyboard does works —
/// autocorrect, dictation, the cursor under a finger — none of which a
/// terminal offers. Nothing reaches the pane until it is sent, and then the
/// whole line goes at once with Enter after it. See `SubmittedLine`.
///
/// **One line, at a fixed height.** This row is in a safe-area bar, and the
/// bar's height is the terminal's height, which is the pane's size on
/// someone's Mac — a field that grew with its text would resize their pane as
/// the user typed.
struct PaneInputField: View {
    let model: PaneModel
    @Binding var draft: String
    var isFocused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 6) {
            TextField("Type a line to send", text: $draft)
                .focused(isFocused)
                // What is typed here is as often a command as a sentence, and
                // a capital on `ls` is a command that does not exist.
                .textInputAutocapitalization(.never)
                .submitLabel(.send)
                .onSubmit {
                    send()
                    // Return gives up focus, and a keyboard that drops after
                    // every line makes a conversation of several a chore.
                    isFocused.wrappedValue = true
                }
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
        // **The draft is kept unless it went.** With no stream the model drops
        // input, and a line that vanished from the field without arriving
        // anywhere is the worst of both.
        guard canSend, let line else { return }
        draft = ""
        Task { await model.submit(line) }
    }
}

// No `#Preview` of its own: it needs a `FocusState` from a parent, and
// `PaneKeyBar` previews it in place.
#endif
