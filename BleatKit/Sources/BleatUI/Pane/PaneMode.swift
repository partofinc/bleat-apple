/// The two ways to read a pane.
///
/// They are not two renderers for one thing; they answer different questions.
/// The terminal shows what the agent actually drew — colour, tables, cursor,
/// live — at the pane's own width, which on a phone means panning. The chat is
/// not the pane at all: it never went through a terminal, because herdr does
/// not have the transcript and cannot — everything herdr knows about an agent
/// it read off the rendered buffer. What herdr provides is the pointer to it.
///
/// **Neither is the better one**, which is why both are offered rather than
/// one in place of the other. The chat is what the screen opens to, since it
/// is the only reading of a pane that reflows to a phone.
///
/// There was a third, a `pane read` snapshot reflowed to the device. It was
/// lossy in the way that mattered most — a pane is a grid of absolutely
/// positioned cells, so anything wide came back re-wrapped into nonsense — and
/// the chat answers the question it was really being opened for.
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
