import BleatKit
import Foundation

/// What the terminal views drive: a live screen, its input, its size.
///
/// **Two of them while Bleat moves to herdr-core.** `PaneModel` is 1.x's,
/// over herdr's `terminal session control`; `HcPaneModel` is Bleat 2's, over
/// hc's `terminal.attach`. The surface, the key bar, the scroll gesture and the
/// SwiftTerm controller are the same for both, so they take this rather than
/// either model, and deleting the herdr one later touches no view.
protocol PaneDriving: AnyObject {
    var phase: PanePhase { get }
    var wantsKeyboard: Bool { get }
    var rowHeight: CGFloat? { get }

    /// Registers the renderer and hands it anything that arrived first.
    func attach(_ sink: @escaping (Data) -> Void)
    /// Registers how a scroll reaches the terminal on screen, for a model that
    /// cannot scroll through its host. See `HcPaneModel.scroll`.
    func attachScroller(_ scroller: @escaping (ScrollDirection, Int) -> Void)
    /// The terminal is now this size.
    func show(_ grid: TerminalGrid)
    func setRowHeight(_ height: CGFloat)
    func retry()
    func setActive(_ active: Bool)
    func setWantsKeyboard(_ wanted: Bool)

    func send(_ key: TerminalKey) async
    func send(_ keys: [TerminalKey], spacedBy pause: Duration) async
    func send(bytes: Data) async
    func submit(_ line: SubmittedLine) async
    func scroll(_ direction: ScrollDirection, notches: Int) async

    func close() async
}

extension PaneDriving {
    func scroll(_ direction: ScrollDirection) async {
        await scroll(direction, notches: 1)
    }
}

extension PaneModel: PaneDriving {
    /// herdr scrolls the pane itself, with `terminal.scroll`; nothing on the
    /// phone needs to.
    func attachScroller(_ scroller: @escaping (ScrollDirection, Int) -> Void) {}
}
