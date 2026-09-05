/// A terminal size in cells.
///
/// A type rather than a tuple because two different sizes are in play and
/// confusing them is the bug this whole screen is about: the **pane's** grid,
/// which is what the host renders and what every line was wrapped to, and the
/// **viewport**, which is however much of it this phone can show at once.
struct TerminalGrid: Equatable, Sendable {
    let cols: Int
    let rows: Int

    var isUsable: Bool { cols > 0 && rows > 0 }
}
