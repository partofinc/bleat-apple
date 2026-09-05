#if canImport(UIKit)
import SwiftTerm
import UIKit

/// Hosts SwiftTerm's `TerminalView` at the **pane's** size and lets the user
/// pan around it.
///
/// A view controller rather than a bare view for the layout hook: the size of a
/// terminal cell depends on the font and is only knowable after a layout pass,
/// and everything here is arithmetic in cells.
///
/// The pane's grid comes from the host (`pane layout`), not from this screen.
/// Sizing the terminal to the phone instead is what made the pane arrive
/// cropped: `observe --cols` is a viewport onto the existing buffer rather than
/// a resize, so a 142-column pane rendered at 53 loses 63% of every line with
/// nothing on screen to say so.
final class PaneTerminalController: UIViewController {
    /// Called with what the phone can show, whenever that changes. It is the
    /// **fallback** size — used only when the host will not report a layout —
    /// and the first call is what starts the stream.
    var onViewport: ((TerminalGrid) -> Void)?
    /// Called once, with the view ready to be fed.
    var onReady: ((TerminalView) -> Void)?

    /// The pane's grid. Set from SwiftUI once the host has reported it; until
    /// then the terminal is sized to the screen so a cell can be measured.
    var grid: TerminalGrid? {
        didSet {
            // `isViewLoaded` so setting this from `makeUIViewController` does
            // not force the view into existence early, before SwiftUI has put
            // the controller anywhere.
            guard grid != oldValue, isViewLoaded else { return }
            view.setNeedsLayout()
        }
    }

    /// Read-only: it renders, and it will not take the keyboard.
    private lazy var terminalView = ReadOnlyTerminalView(frame: .zero, font: nil)
    /// Owns panning, because the terminal is deliberately larger than the
    /// screen. `TerminalView` is itself a `UIScrollView`, so its own scrolling
    /// is turned off rather than nested inside this one — two scroll views
    /// competing for the same drag is how a pane becomes impossible to move.
    private let scrollView = UIScrollView()
    private var reported: TerminalGrid?
    private var announced = false
    private var flashed = false

    override func viewDidLoad() {
        super.viewDidLoad()
        terminalView.terminalDelegate = self
        terminalView.isScrollEnabled = false
        scrollView.addSubview(terminalView)
        scrollView.showsHorizontalScrollIndicator = true
        scrollView.showsVerticalScrollIndicator = true
        // The sliver of slack below, and any area a pane narrower than the
        // screen does not cover, should look like the terminal rather than
        // like a gap in it.
        scrollView.backgroundColor = terminalView.nativeBackgroundColor
        view.backgroundColor = terminalView.nativeBackgroundColor
        view.addSubview(scrollView)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        scrollView.frame = view.bounds

        // **The terminal is never sized to the screen and then to the grid in
        // one pass.** `TerminalView` reflows its buffer on every size change,
        // and the `observe` stream sends a full redraw only when it opens — so
        // a stray intermediate size scrambles the screen with nothing left to
        // repaint it. No bootstrap pass is needed for the measurement either:
        // `cellDimension` comes from the font at init, not from the frame.
        guard let cell = cellSize(),
              scrollView.bounds.width > 0, scrollView.bounds.height > 0
        else { return }

        let viewport = TerminalGrid(
            cols: Int(scrollView.bounds.width / cell.width),
            rows: Int(scrollView.bounds.height / cell.height)
        )
        resizeTerminal(to: grid ?? viewport, cell: cell)

        if !announced {
            announced = true
            onReady?(terminalView)
        }
        report(viewport)
    }

    /// One cell, in points.
    ///
    /// Derived rather than read: SwiftTerm keeps `cellDimension` internal, but
    /// `getOptimalFrameSize()` is public and returns exactly
    /// `cellDimension × (cols, rows)`, so dividing by the terminal's own size
    /// recovers it without guessing at a font metric.
    private func cellSize() -> CGSize? {
        let terminal = terminalView.getTerminal()
        let optimal = terminalView.getOptimalFrameSize()
        guard terminal.cols > 0, terminal.rows > 0,
              optimal.width > 0, optimal.height > 0
        else { return nil }
        return CGSize(
            width: optimal.width / CGFloat(terminal.cols),
            height: optimal.height / CGFloat(terminal.rows)
        )
    }

    /// Makes the terminal exactly `grid` cells, whatever the screen is.
    ///
    /// `TerminalView` derives its size from its own bounds — `Int(width /
    /// cellWidth)` — and there is no public setter, so the frame is the only
    /// way to ask for a number of columns. Landing exactly on `cols * cellWidth`
    /// would put that division on a boundary where an error of one ulp costs a
    /// whole column, and a terminal one column narrower than the stream it is
    /// being fed wraps every single line. Rounding up and adding half a point
    /// clears the boundary by far more than any floating-point error and by far
    /// less than a cell, so it can neither lose a column nor gain one — and the
    /// sliver is painted in the terminal's own background.
    private func resizeTerminal(to grid: TerminalGrid, cell: CGSize) {
        let size = CGSize(
            width: (cell.width * CGFloat(grid.cols)).rounded(.up) + 0.5,
            height: (cell.height * CGFloat(grid.rows)).rounded(.up) + 0.5
        )
        if terminalView.frame.size != size {
            terminalView.frame = CGRect(origin: .zero, size: size)
            terminalView.layoutIfNeeded()
        }
        scrollView.contentSize = size

        // Shown once, when there is something off-screen to find. The pane is
        // wider than the phone by design now, and a scroll indicator that only
        // appears once you already know to drag is not an affordance.
        if !flashed, size.width > scrollView.bounds.width || size.height > scrollView.bounds.height {
            flashed = true
            scrollView.flashScrollIndicators()
        }
    }

    /// Deduplicated, because both the layout pass and the delegate report the
    /// same change and either may come first.
    private func report(_ grid: TerminalGrid) {
        guard grid.isUsable, reported != grid else { return }
        reported = grid
        onViewport?(grid)
    }
}

/// Every method is a no-op, and that is the point: this is an observer.
///
/// The protocol has no default implementations, so each one has to be written
/// out. Two are worth saying out loud — `send` is where keystrokes would go and
/// there is nowhere to send them until Phase 3, and `clipboardRead` returning
/// nil means the remote cannot reach into this device's pasteboard.
extension PaneTerminalController: TerminalViewDelegate {
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        // Not the remote asking for 132 columns, whatever the protocol's own
        // documentation suggests: SwiftTerm fires this from `processSizeChange`
        // when the *view's* geometry changes what fits.
        //
        // It is only the viewport while the terminal is still screen-sized.
        // Once the grid is applied the terminal *is* the pane, and its cols are
        // the pane's — reporting those as "what the phone can show" would make
        // the fallback, on a host that never reported a layout, hold whatever
        // this screen last happened to render.
        guard grid == nil else { return }
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
