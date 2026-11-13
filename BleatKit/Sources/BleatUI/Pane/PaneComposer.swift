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
                    // Read again every second: the paste mode lives in the
                    // terminal and is not observable, and zsh turns it off
                    // and on around every command (from review).
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(footer)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    }
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

    /// Clears and closes at once, and puts the text back if there was no
    /// stream to take it, so a long prompt is not lost to a dropped
    /// connection (from review). Queued is as far as the promise goes.
    private func send() {
        guard canSend, let line else { return }
        let written = text
        text = ""
        dismiss()
        Task {
            guard !(await model.submit(line)), text.isEmpty else { return }
            text = written
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
