import BleatKit
import Foundation

/// One cap on the shortcut strip: a key, or the same key more than once.
///
/// **These go to the program in the pane, not to herdr.** herdr's own
/// keybindings belong to its terminal UI, and the stream this app holds
/// delivers input past that, straight to the pane — so a herdr prefix sent
/// from here would arrive at the shell as a control character.
struct PaneShortcut: Identifiable, Hashable {
    /// What is printed on the cap, in the notation a Mac keyboard uses.
    let label: String
    /// What it is for, read out in place of the notation.
    let name: String
    let keys: [TerminalKey]
    /// Whether it ends something. Drawn in red, and nothing more: it is still
    /// one tap, because being one tap is what it is for.
    var endsTheProgram = false

    var id: String { label }

    /// Between the presses of a shortcut that has more than one. See
    /// `PaneModel.send(_:spacedBy:)`.
    static let pause = Duration.milliseconds(300)

    /// In the order they are reached for. Interrupt first, because it is the
    /// one wanted in a hurry.
    static let all: [PaneShortcut] = [
        PaneShortcut(label: "⌃C", name: "Interrupt", keys: [.controlC]),
        // **Measured, 1 Oct 2026:** two Ctrl-C, 300ms apart, took an idle
        // Claude Code back to the shell. One only clears its input.
        PaneShortcut(
            label: "⌃C ⌃C", name: "Exit the agent",
            keys: [.controlC, .controlC], endsTheProgram: true
        ),
        PaneShortcut(label: "tab", name: "Tab", keys: [.tab]),
        PaneShortcut(label: "⇧tab", name: "Shift Tab", keys: [.backTab]),
        PaneShortcut(label: "⌃R", name: "Search history", keys: [.controlR]),
        PaneShortcut(label: "⌃O", name: "Expand output", keys: [.controlO]),
        PaneShortcut(label: "⌃U", name: "Clear the line", keys: [.controlU]),
        PaneShortcut(label: "⌃L", name: "Clear the screen", keys: [.controlL]),
        PaneShortcut(label: "⌃D", name: "End of input", keys: [.controlD]),
    ]
}
