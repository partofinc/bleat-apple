import BleatKit
import Foundation

/// What the terminal views drive: a live screen, its input, its size.
///
/// `HcPaneModel` drives them over hc's `terminal.attach`. The surface, the key
/// bar, the scroll gesture and the SwiftTerm controller take this rather than
/// the model: they outlived 1.x's herdr model this way, and a preview or a
/// test can drive them with something else.
protocol PaneDriving: AnyObject {
    var phase: PanePhase { get }
    var wantsKeyboard: Bool { get }
    var rowHeight: CGFloat? { get }
    /// Whether the program has bracketed paste on (`attachPasteMode`).
    var acceptsPaste: Bool { get }

    /// Registers the renderer and hands it anything that arrived first.
    func attach(_ sink: @escaping (Data) -> Void)
    /// Registers how a scroll reaches the terminal on screen, for a model that
    /// cannot scroll through its host. See `HcPaneModel.scroll`.
    func attachScroller(_ scroller: @escaping (ScrollDirection, Int) -> Void)
    /// Registers how to ask the terminal on screen whether the program has
    /// bracketed paste on, so several lines can go as one (`SubmittedLine`).
    func attachPasteMode(_ isOn: @escaping () -> Bool)
    /// The terminal is now this size.
    func show(_ grid: TerminalGrid)
    func setRowHeight(_ height: CGFloat)
    func retry()
    func setActive(_ active: Bool)
    func setWantsKeyboard(_ wanted: Bool)

    func send(_ key: TerminalKey) async
    func send(_ keys: [TerminalKey], spacedBy pause: Duration) async
    func send(bytes: Data) async
    /// Whether it went to a live stream; false when there was none to take it.
    @discardableResult
    func submit(_ line: SubmittedLine) async -> Bool
    func scroll(_ direction: ScrollDirection, notches: Int) async

    func close() async
}

extension PaneDriving {
    func scroll(_ direction: ScrollDirection) async {
        await scroll(direction, notches: 1)
    }
}
