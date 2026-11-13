#if canImport(UIKit) && !os(watchOS)
import SwiftUI
import UIKit

/// The composer's text view: one that leaves what was typed alone — no smart
/// quotes or dashes, which would rewrite the characters a command is made
/// of. See `PaneLineField`, the one-line case.
///
/// **Autocorrect stays on**, as in `PaneLineField` and kept after review:
/// it offers a change and can be declined, where smart punctuation
/// substitutes without asking, and this is mostly where prompts are written.
struct PaneTextView: UIViewRepresentable {
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
#endif
