#if canImport(UIKit) && !os(watchOS)
import SwiftUI
import UIKit

/// A one-line field for what the host reads literally — a command line, a
/// path, a name — so it arrives as typed.
///
/// **A `UITextField` because SwiftUI's cannot turn Smart Punctuation off**
/// (`.autocorrectionDisabled()` does not), as `PaneLineField` says. From the
/// new-terminal sheet, `claude --continue` ran on the Mac as `claude
/// —continue`, an em dash: Claude took it for a first message and started a
/// new conversation instead of continuing one (14 Nov 2026). Curly quotes
/// would break a shell's quoting the same way. Autocorrect is off too: none
/// of these is a sentence.
///
/// **No clear button** (from review): `UITextField`'s clears without an
/// `editingChanged`, so a command that looked gone still ran on Start.
///
/// **Return ends editing before it submits** (from review), so a start that
/// fails says so in a form the keyboard no longer covers.
struct LiteralTextField: UIViewRepresentable {
    let placeholder: String
    @Binding var text: String
    var returnKey: UIReturnKeyType = .default
    var onSubmit: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.placeholder = placeholder
        field.font = Self.font
        field.adjustsFontForContentSizeCategory = true
        field.typesLiterally()
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.returnKeyType = returnKey
        field.delegate = context.coordinator
        field.addTarget(
            context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged
        )
        // The row decides the width: a long command must not push the
        // directory menu off the end.
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    /// Body, monospaced, at the reader's text size. Scaled from body's size at
    /// the default setting: scaling the current size scaled it twice (from
    /// review).
    private static var font: UIFont {
        let base = UIFont.preferredFont(
            forTextStyle: .body, compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)
        )
        return UIFontMetrics(forTextStyle: .body).scaledFont(
            for: .monospacedSystemFont(ofSize: base.pointSize, weight: .regular)
        )
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self
        if field.text != text { field.text = text }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: LiteralTextField

        init(_ parent: LiteralTextField) { self.parent = parent }

        @objc func changed(_ field: UITextField) {
            parent.text = field.text ?? ""
        }

        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            field.resignFirstResponder()
            parent.onSubmit?()
            return false
        }
    }
}

// No `#Preview` of its own: `NewTerminalSheet` previews it in place.
#endif
