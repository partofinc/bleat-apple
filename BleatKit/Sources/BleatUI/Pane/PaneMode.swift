/// The two ways to read a pane.
///
/// They are not two renderers for one thing; they answer different questions.
/// The terminal shows what the agent actually drew — colour, tables, cursor,
/// live — at the pane's own width, which on a phone means panning. The reader
/// throws all of that away for the one thing the terminal cannot do: reflow to
/// the width of the device in your hand.
///
/// **Neither is the better one.** The reader is lossy in ways that matter — see
/// `PaneReaderView` — so it is offered beside the terminal rather than in place
/// of it, and the terminal stays the default.
enum PaneMode: CaseIterable, Identifiable {
    case terminal
    case reader

    var id: Self { self }

    var label: String {
        switch self {
        case .terminal: "Terminal"
        case .reader: "Reader"
        }
    }

    var symbol: String {
        switch self {
        case .terminal: "apple.terminal"
        case .reader: "text.alignleft"
        }
    }
}
