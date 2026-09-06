/// A terminal size in cells.
///
/// A type rather than a tuple because two different sizes are in play and
/// confusing them is the bug this whole screen is about: the **pane's** grid,
/// which is what the host renders and what every line was wrapped to, and the
/// **viewport**, which is however much of it this phone can show at once.
public struct TerminalGrid: Equatable, Sendable {
    public let cols: Int
    public let rows: Int

    public init(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
    }

    public var isUsable: Bool { cols > 0 && rows > 0 }
}
