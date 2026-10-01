#if canImport(UIKit)
import SwiftUI
import UIKit

/// A one-line text field that leaves what was typed alone.
///
/// **A `UITextField` because SwiftUI's cannot turn Smart Punctuation off.**
/// It is on by default, and it rewrites exactly the characters a command is
/// made of: `git log --oneline` becomes `git log —oneline`, and the quotes in
/// `git commit -m "fix"` become curly ones a shell reads as letters. The line
/// that ran on the Mac would not be the line that was typed. Autocorrect stays
/// — it offers, where smart punctuation substitutes — and so does dictation.
///
/// **Return sends and keeps the keyboard.** `textFieldShouldReturn` answers
/// false, so focus never leaves; a SwiftUI field gives it up on Return and has
/// to be handed it back, which drops the keyboard for a frame — and a keyboard
/// that hides is a `keyboardDidHide`, which thaws the pane's frozen grid.
struct PaneLineField: UIViewRepresentable {
    let placeholder: String
    @Binding var text: String
    @Binding var isFocused: Bool
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.placeholder = placeholder
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.returnKeyType = .send
        field.enablesReturnKeyAutomatically = true
        // What is typed here is as often a command as a sentence, and a
        // capital on `ls` is a command that does not exist.
        field.autocapitalizationType = .none
        field.smartDashesType = .no
        field.smartQuotesType = .no
        field.smartInsertDeleteType = .no
        field.delegate = context.coordinator
        field.addTarget(
            context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged
        )
        // The row decides the size; without these the field's own width
        // pushes the send button off the end of a long line.
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self
        if field.text != text { field.text = text }
        // Only on a disagreement, and never inside this pass: taking or
        // giving up first responder writes the binding back.
        guard field.isFirstResponder != isFocused else { return }
        let wanted = isFocused
        Task { @MainActor in
            guard field.isFirstResponder != wanted else { return }
            _ = wanted ? field.becomeFirstResponder() : field.resignFirstResponder()
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: PaneLineField

        init(_ parent: PaneLineField) { self.parent = parent }

        @objc func changed(_ field: UITextField) {
            parent.text = field.text ?? ""
        }

        func textFieldDidBeginEditing(_ field: UITextField) {
            if !parent.isFocused { parent.isFocused = true }
        }

        func textFieldDidEndEditing(_ field: UITextField) {
            if parent.isFocused { parent.isFocused = false }
        }

        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            parent.onSubmit()
            return false
        }
    }
}

// No `#Preview` of its own: `PaneKeyBar` previews it in place.
#endif
