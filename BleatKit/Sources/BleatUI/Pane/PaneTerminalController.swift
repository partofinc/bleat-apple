#if canImport(UIKit)
import SwiftTerm
import UIKit

/// Hosts SwiftTerm's `TerminalView` at the **pane's** size, fitted to the screen
/// by scaling the font.
///
/// A view controller rather than a bare view for the layout hook: the size of a
/// terminal cell depends on the font and is only knowable after a layout pass,
/// and everything here is arithmetic in cells.
///
/// **Nothing is cut, and that is the point.** Asking the host for fewer columns
/// does not reflow the pane, it crops it — re-verified 6 Sept 2026, a line of
/// `A`x60 + `B`x60 + `C`x54 into a 174-column pane observed at `--cols 60` came
/// back with the B's and C's simply gone. So the full grid is always requested
/// and the type is what gives: the font is sized so the pane's whole width spans
/// the screen.
///
/// That is an honest trade rather than a free win. 142 columns across a 393pt
/// iPhone is 2.77pt per cell, which is too small to read — so fit is the
/// *starting* point and a pinch takes it back up, at which point the scroll view
/// earns its keep. Rotation re-fits, unless the user has already chosen a size.
final class PaneTerminalController: UIViewController {
    /// Called with what the phone can show, whenever that changes. It is the
    /// **fallback** size — used only when the host will not report a layout —
    /// and the first call is what starts the stream.
    var onViewport: ((TerminalGrid) -> Void)?
    /// Called once, with the view ready to be fed.
    var onReady: ((TerminalView) -> Void)?
    /// Called with the grid the terminal is now actually rendering at.
    ///
    /// Frames are only safe to feed once this matches what the stream was
    /// opened at: they carry absolute cursor positioning, so a frame written
    /// for 142 columns into a 53-column terminal wraps every line, and the
    /// stream sends a full redraw only when it opens — nothing would repair it.
    var onGridApplied: ((TerminalGrid) -> Void)?

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
    /// Owns any panning that is left. `TerminalView` is itself a
    /// `UIScrollView`, so its own scrolling is turned off rather than nested
    /// inside this one — two scroll views competing for the same drag is how a
    /// pane becomes impossible to move.
    private let scrollView = UIScrollView()
    private var reported: TerminalGrid?
    private var announced = false
    private var flashed = false

    /// Point size of the terminal font.
    ///
    /// **This is what stops the pane being cut.** The grid is the pane's, which
    /// is 142 columns on the dev Mac, and no client can make the host send
    /// fewer without losing the difference — `--cols` crops. So the columns stay
    /// and the type shrinks: the size is chosen so the whole grid spans the
    /// screen. On a 393pt-wide iPhone that is 393/142 = 2.77pt per cell, which
    /// is honestly too small to read — hence the pinch. Fit is the starting
    /// point, not the only one.
    /// Whether the user has pinched. Once they have, rotating must not throw
    /// their chosen size away.
    private var fontSizeIsChosen = false

    private enum FontSize {
        /// Below this, glyphs stop being glyphs — at 3x, 4pt type is about
        /// twelve device pixels tall. Fit is still allowed to go here, because
        /// seeing the *shape* of a full-width pane is worth something even
        /// unread, and the pinch is right there.
        static let min: CGFloat = 3
        static let max: CGFloat = 24
        /// SwiftTerm's own default, and the ceiling for fitting: a narrow pane
        /// should not be blown up to fill the screen.
        static let natural: CGFloat = UIFont.systemFontSize
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        terminalView.terminalDelegate = self
        terminalView.isScrollEnabled = false
        // Pinch changes the font rather than zooming the layer. Scaling a
        // rasterised terminal blurs it; re-rendering at the new size keeps every
        // glyph sharp, and it is the same code path the fit uses.
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch))
        scrollView.addGestureRecognizer(pinch)
        scrollView.addSubview(terminalView)
        scrollView.showsHorizontalScrollIndicator = true
        scrollView.showsVerticalScrollIndicator = true
        // The sliver of slack below, and any area the pane does not cover,
        // should look like the terminal rather than like a gap in it. A 47-row
        // pane leaves ~50pt bare under a portrait iPhone, plus the whole
        // rubber-band overscroll region.
        //
        // Read off the **layer**, not `nativeBackgroundColor`: SwiftTerm's
        // `setupOptions` moves the real colour into `layer.backgroundColor` and
        // then sets that property to `UIColor.clear`, so asking the obvious
        // thing paints a transparent band — white under a black terminal in
        // light mode.
        let background = terminalView.layer.backgroundColor.map(UIColor.init(cgColor:))
        scrollView.backgroundColor = background
        view.backgroundColor = background
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
        guard scrollView.bounds.width > 0, scrollView.bounds.height > 0 else { return }

        // Fit before measuring: the cell size *is* the font, so choosing the
        // font first is what makes the arithmetic below land on the screen.
        applyFontIfNeeded()

        guard let cell = cellSize() else { return }

        let viewport = TerminalGrid(
            cols: Int(scrollView.bounds.width / cell.width),
            rows: Int(scrollView.bounds.height / cell.height)
        )
        let applied = grid ?? viewport
        resizeTerminal(to: applied, cell: cell)
        onGridApplied?(applied)

        if !announced {
            announced = true
            onReady?(terminalView)
        }
        report(viewport)
    }

    /// Sets the font so the pane's full width spans the screen.
    ///
    /// Cell width is linear in point size for a monospaced face, so one
    /// measurement at the current size gives the scale factor for any other. It
    /// is clamped at the top to SwiftTerm's natural size — a 40-column pane
    /// should not be blown up to fill a phone — and at the bottom only by what
    /// is still a glyph.
    private func applyFontIfNeeded() {
        guard !fontSizeIsChosen, let grid, grid.cols > 0 else { return }
        guard let cell = cellSize(), cell.width > 0 else { return }

        let current = terminalView.font.pointSize
        let wanted = current * (scrollView.bounds.width / (cell.width * CGFloat(grid.cols)))
        let clamped = min(FontSize.natural, max(FontSize.min, wanted))
        setFontSize(clamped)
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began, .changed:
            fontSizeIsChosen = true
            setFontSize(terminalView.font.pointSize * gesture.scale)
            gesture.scale = 1
        default:
            break
        }
    }

    /// Applies a size and re-lays out, if it actually differs.
    ///
    /// Guarded on a real change because setting `font` calls SwiftTerm's
    /// `resetFont`, which reflows the buffer — and `viewDidLayoutSubviews` runs
    /// often enough that an unguarded write would reflow on every pass.
    private func setFontSize(_ size: CGFloat) {
        let size = min(FontSize.max, max(FontSize.min, size))
        guard abs(size - terminalView.font.pointSize) > 0.01 else { return }
        terminalView.font = UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
        view.setNeedsLayout()
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

        // Shown once, if there is anything off-screen to find. Normally there
        // is not — the terminal is sized to this screen — so this rarely fires,
        // and that is the correct outcome rather than dead code: it is what
        // covers the rounding case and any future size that does overflow.
        //
        // The tolerance has to be wider than the half-point padding added
        // above, or a terminal derived from these very bounds reads as "there
        // is more over there".
        let slack: CGFloat = 2
        let overflows = size.width > scrollView.bounds.width + slack
            || size.height > scrollView.bounds.height + slack
        if !flashed, self.grid != nil, overflows {
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
