#if canImport(UIKit) && !os(watchOS)
import BleatKit
import SwiftUI
import UIKit

/// Writing a prompt of several lines, then sending it whole.
///
/// **A sheet, because the bar cannot grow.** The key bar's height is the
/// terminal's height and so the pane's size on someone's Mac (`PaneKeyBar`);
/// a field that grew with its text would reflow their agent as the user
/// typed. The sheet's keyboard freezes the grid like any other
/// (`PaneTerminalController.keyboardWillShow`).
///
/// **Several lines arrive as one only where the program takes a paste**
/// (`SubmittedLine`): Claude Code and zsh do; elsewhere they are joined with
/// spaces, and the footer says which before anything is sent.
struct PaneComposer: View {
    let model: any PaneDriving
    /// Kept by the key bar, so a prompt half written survives closing this.
    @Binding var text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            PaneTextView(text: $text)
                .padding(.horizontal, 12)
                .safeAreaInset(edge: .bottom) {
                    Text(footer)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                }
                .navigationTitle("Compose")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        // Kept, not discarded: it is still here next time.
                        Button("Close") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Send", systemImage: "arrow.up", action: send)
                            .disabled(!canSend)
                    }
                }
        }
    }

    private var line: SubmittedLine? { SubmittedLine(text) }

    private var canSend: Bool { line != nil && model.phase == .live }

    private var footer: String {
        guard model.phase == .live else { return "Not connected to the terminal; it is kept until it is." }
        guard let line, line.isMultiline else { return "Sent, then Return." }
        return model.acceptsPaste
            ? "Sent as one paste, then Return."
            : "This program reads a line at a time, so line breaks go as spaces."
    }

    private func send() {
        guard canSend, let line else { return }
        text = ""
        dismiss()
        Task { await model.submit(line) }
    }
}

/// A text view that leaves what was typed alone: no smart quotes or dashes,
/// which would rewrite the characters a command is made of. See
/// `PaneLineField`, which is the one-line case.
private struct PaneTextView: UIViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.autocapitalizationType = .none
        view.smartDashesType = .no
        view.smartQuotesType = .no
        view.smartInsertDeleteType = .no
        view.text = text
        view.delegate = context.coordinator
        // Up with the sheet: writing is why it was opened.
        Task { @MainActor in view.becomeFirstResponder() }
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.text = $text
        if view.text != text { view.text = text }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var text: Binding<String>

        init(text: Binding<String>) { self.text = text }

        func textViewDidChange(_ view: UITextView) {
            text.wrappedValue = view.text
        }
    }
}

#if DEBUG
#Preview("Compose", traits: .sampleData) {
    @Previewable @State var text = "Look at the failing test in HcRunTests,\nthen fix it."
    Color.black.sheet(isPresented: .constant(true)) {
        PaneComposer(model: HcPaneModel(previewing: .live), text: $text)
    }
}
#endif
#endif
