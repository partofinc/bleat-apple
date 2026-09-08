/// The two ways to read a pane.
///
/// They are not two renderers for one thing; they answer different questions.
/// The terminal shows what the agent actually drew — colour, tables, cursor,
/// live — at the pane's own width, which on a phone means panning. The reader
/// throws all of that away for the one thing the terminal cannot do: reflow to
/// the width of the device in your hand.
///
/// **None of them is the better one.** The reader is lossy in ways that matter
/// — see `PaneReaderView` — and the transcript is not the pane at all, so both
/// are offered beside the terminal rather than in place of it, and the terminal
/// stays the default.
///
/// The third is a different kind of thing from the first two. Terminal and
/// reader are both the *screen*: 142 columns because that is the pty, wrapped by
/// whatever drew it. The transcript never went through a terminal — herdr does
/// not have it and cannot, since everything herdr knows about an agent it read
/// off the rendered buffer. What herdr provides is the pointer to it.
enum PaneMode: CaseIterable, Identifiable {
    /// The default, and it is the chat rather than the terminal.
    ///
    /// An agent screen is opened to read what the agent said, and that is the
    /// one thing the terminal cannot do well on a phone: the pane is 142
    /// columns because that is the pty, so portrait shows about the left third
    /// of every line. The chat was never wrapped to anything and reflows.
    case chat
    case terminal

    var id: Self { self }

    var label: String {
        switch self {
        case .terminal: "Terminal"
        case .chat: "Chat"
        }
    }

    var symbol: String {
        switch self {
        case .terminal: "apple.terminal"
        case .chat: "bubble.left.and.bubble.right"
        }
    }
}
