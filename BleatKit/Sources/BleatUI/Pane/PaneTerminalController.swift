#if canImport(UIKit)
import BleatKit
import SwiftTerm
import UIKit

/// Hosts SwiftTerm's `TerminalView`, filling the screen.
///
/// **It sizes itself, and that is the whole design.** `TerminalView` derives its
/// columns and rows from its own bounds, so a terminal that fills the screen is
/// by definition the number of cells this phone can show at a readable size.
/// That number is reported upwards, the host is asked to make the pane's pty
/// exactly that, and the stream is opened at it — so every size in the system is
/// the same one and there is nothing to reconcile.
///
/// Everything that used to live here — fitting a font to a grid, an outer scroll
/// view to pan a terminal wider than the screen, a pinch multiplier, a cache key
/// to stop the fit looping — existed to cope with a pane whose width was not
/// this phone's. Resizing the pty removed the problem rather than managing it.
///
/// A view controller rather than a bare view for the layout hook: the size is
/// only knowable after a layout pass.
final class PaneTerminalController: UIViewController {
    /// The grid the terminal is showing, whenever it changes. Both "what to ask
    /// the host for" and "what the stream is being rendered at" — they are the
    /// same number now, which is why there is one callback instead of two.
    var onSize: ((TerminalGrid) -> Void)?
    /// Called once, with the view ready to be fed.
    var onReady: ((TerminalView) -> Void)?

    /// Read-only: it renders, and it will not take the keyboard.
    private lazy var terminalView = ReadOnlyTerminalView(frame: .zero, font: nil)
    private var reported: TerminalGrid?
    private var announced = false

    override func viewDidLoad() {
        super.viewDidLoad()
        terminalView.terminalDelegate = self
        // **Scrollback, natively.** `TerminalView` is itself a `UIScrollView`
        // and keeps its own buffer; this was off while an outer scroll view
        // panned a terminal wider than the screen, because two scroll views
        // competing for one drag make a pane unmovable. There is no outer one
        // now, so this is simply how scrolling back works — and it is the only
        // scrollback available: `observe` ignores `terminal.scroll`, verified
        // 6 Sept 2026 by sending one and getting a single frame and no reply,
        // so the host cannot be asked to scroll on a reader's behalf.
        terminalView.isScrollEnabled = true

        // Read off the **layer**, not `nativeBackgroundColor`: SwiftTerm's
        // `setupOptions` moves the real colour into `layer.backgroundColor` and
        // sets that property to `UIColor.clear`, so asking the obvious thing
        // paints a transparent band — white under a black terminal in light
        // mode.
        view.backgroundColor = terminalView.layer.backgroundColor.map(UIColor.init(cgColor:))
        view.addSubview(terminalView)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard view.bounds.width > 0, view.bounds.height > 0 else { return }
        terminalView.frame = view.bounds
        // `TerminalView` recomputes its cols and rows in its own
        // `layoutSubviews`, which runs *after* this method — so without forcing
        // it, the size read below is `TerminalOptions`' default 80x25, a size
        // the view cannot show and the host would be asked for anyway.
        terminalView.layoutIfNeeded()

        let terminal = terminalView.getTerminal()
        report(TerminalGrid(cols: terminal.cols, rows: terminal.rows))

        if !announced {
            announced = true
            onReady?(terminalView)
        }
    }

    /// Deduplicated, because the layout pass and the delegate report the same
    /// change and either may come first.
    private func report(_ grid: TerminalGrid) {
        guard grid.isUsable, reported != grid else { return }
        reported = grid
        onSize?(grid)
    }
}

/// Every method is a no-op, and that is the point: this is an observer.
///
/// The protocol has no default implementations, so each one has to be written
/// out. Three are refusals rather than omissions — see `send`, `clipboardCopy`
/// and `requestOpenLink`.
extension PaneTerminalController: TerminalViewDelegate {
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        // Not the remote asking for 132 columns, whatever the protocol's own
        // documentation suggests: SwiftTerm fires this from `processSizeChange`
        // when the *view's* geometry changes what fits. It is the correctly
        // timed answer, and ignoring it is how a wrong size goes uncorrected.
        report(TerminalGrid(cols: newCols, rows: newRows))
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        // The screen is titled from `agent list`, which is a name the user
        // recognises; a pane's own title changes with whatever it is running.
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        // Phase 3. Dropping input silently is correct for now: the alternative
        // is `terminal session control`, which seizes the pane from whoever
        // holds it.
    }

    func scrolled(source: TerminalView, position: Double) {}

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        // Deliberately not opened. The link comes from output on a remote
        // machine, and following one on tap would let anything a pane prints
        // send this phone to a URL of its choosing.
    }

    func bell(source: TerminalView) {}

    func clipboardCopy(source: TerminalView, content: Data) {
        // OSC 52 from the host. Not honoured: a remote pane writing to the
        // phone's pasteboard is not something the user asked for.
    }

    func clipboardRead(source: TerminalView) -> Data? { nil }

    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
#endif
