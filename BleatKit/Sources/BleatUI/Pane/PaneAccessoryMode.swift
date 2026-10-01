import Foundation

/// What the top row of the pane's accessory holds.
///
/// The bottom row — arrows, `esc`, return — is there in both, because a
/// dialog needs answering whichever is showing.
enum PaneAccessoryMode: String, CaseIterable, Identifiable {
    /// A text field: a line is composed with the system keyboard and sent
    /// whole, with Enter after it.
    case input
    /// The keys a phone's keyboard has no key for.
    case shortcuts

    var id: Self { self }

    var title: String {
        switch self {
        case .input: "Text Field"
        case .shortcuts: "Shortcuts"
        }
    }

    var symbol: String {
        switch self {
        case .input: "character.cursor.ibeam"
        case .shortcuts: "command"
        }
    }
}
