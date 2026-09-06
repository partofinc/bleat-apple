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
/// The fit takes both axes and the smaller scale wins, but it stops at a
/// readable floor rather than shrinking without limit. The arithmetic decides
/// what that means per orientation: 142 columns across a 393pt portrait iPhone
/// wants 2.77pt cells — about 4.6pt type, the whole pane and none of it legible
/// — so portrait settles at the floor and pans. Landscape's 852pt over the same
/// 142 columns is 6pt cells, around 10pt type, which fits entirely and reads
/// fine. Pinch overrides either, down to a size only a shape is visible at, and
/// rotation re-fits unless the user has already chosen.
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
    /// The user's pinch, as a multiple of the fitted size rather than an
    /// absolute one.
    ///
    /// **A multiplier is what lets rotation keep working.** The first version
    /// stored "the user has chosen a size" and stopped fitting for good — so
    /// after a single pinch the terminal never adapted to an orientation change
    /// again, which is most of what a phone does. Kept relative, the fit is
    /// recomputed for the new screen and the user's zoom rides on top of it.
    private var zoom: CGFloat = 1
    /// SwiftTerm's own starting size, captured in `viewDidLoad` before anything
    /// changes it — not lazily, or its value would depend on whether the fit had
    /// already run. The ceiling for fitting: a 40-column pane should not be
    /// blown up to fill a phone just because it would fit.
    private var naturalFontSize: CGFloat = UIFont.systemFontSize
    /// What the current fit was computed for. A settled fit is never recomputed,
    /// which is what keeps the font change idempotent across layout passes.
    private var fitted: FitKey?

    private struct FitKey: Equatable {
        let cols: Int
        let rows: Int
        let zoom: CGFloat
        /// Rounded, because bounds that jitter by a hundredth of a point would
        /// otherwise invalidate the fit on every layout pass and re-run the
        /// measurement loop forever.
        let width: CGFloat
        let height: CGFloat

        init(cols: Int, rows: Int, size: CGSize, zoom: CGFloat) {
            self.cols = cols
            self.rows = rows
            self.zoom = zoom
            self.width = (size.width * 2).rounded() / 2
            self.height = (size.height * 2).rounded() / 2
        }
    }

    private enum FontSize {
        /// The floor for a *pinch*. Below this glyphs stop being glyphs, but
        /// someone deliberately zooming out to see the shape of a pane may go
        /// there.
        static let min: CGFloat = 3
        static let max: CGFloat = 24
        /// The floor for the automatic fit, which is a different question:
        /// what is worth *opening* at.
        ///
        /// Fitting 142 columns into a 393pt portrait iPhone needs 2.77pt cells,
        /// about 4.6pt type — the whole pane, and none of it readable. Landscape
        /// is the opposite: 852pt over 142 columns is 6pt cells, around 10pt
        /// type, which fits entirely and reads fine. So the fit is allowed to
        /// shrink until it either fits or reaches this, and portrait lands here
        /// and pans while landscape genuinely fits.
        ///
        /// Opening unreadable was the wrong default: nothing is lost by panning,
        /// and everything is lost by not being able to read it.
        static let readable: CGFloat = 9
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
        naturalFontSize = terminalView.font.pointSize
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
        // It settles within this pass and never asks for another one.
        fitFontIfNeeded()

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
    /// **It must converge inside one layout pass, and it must not ask for
    /// another.** The first version adjusted the font and called
    /// `setNeedsLayout`, expecting to settle over a few passes. It froze the
    /// app. Cell width is *not* a continuous function of point size — glyph
    /// advances are quantised, so two nearby sizes can produce the same cell and
    /// the correction flips between them forever, each flip requesting one more
    /// pass. An unbounded feedback loop through UIKit's layout engine is a hang,
    /// not a slow convergence.
    ///
    /// So: a bounded number of measure-and-adjust steps here, no relayout
    /// request, and a cache key so a settled fit is never recomputed. The key is
    /// what makes the whole thing idempotent — `viewDidLayoutSubviews` runs
    /// often, and the only safe number of font changes per (grid, size) is one.
    ///
    /// **Both dimensions are fitted, and the smaller scale wins.** Width is
    /// nearly always the binding one on a phone — 47 rows of a 142-column pane
    /// need a third of the type height that the columns need of the width — but
    /// a short wide pane exists and fitting only one axis would overflow the
    /// other with nothing said about it.
    private func fitFontIfNeeded() {
        guard let grid, grid.cols > 0, grid.rows > 0 else { return }
        let available = scrollView.bounds.size
        let key = FitKey(cols: grid.cols, rows: grid.rows, size: available, zoom: zoom)
        guard fitted != key else { return }
        fitted = key

        // Solved rather than iterated towards. Cell size is linear in point
        // size for a monospaced face, so one measurement gives points-per-cell
        // and the answer follows directly — no feedback, and therefore no loop
        // to get wrong. The second pass exists only because glyph advances are
        // quantised, so the first answer can land a fraction off.
        for _ in 0..<2 {
            guard let cell = cellSize(), cell.width > 0, cell.height > 0 else { return }
            let point = terminalView.font.pointSize
            let perPoint = CGSize(width: cell.width / point, height: cell.height / point)

            let fit = min(
                available.width / (perPoint.width * CGFloat(grid.cols)),
                available.height / (perPoint.height * CGFloat(grid.rows))
            )
            // The fit is what the screen can take; the zoom is what the user
            // asked for on top of it. They clamp differently — the fit stops at
            // a readable size and at SwiftTerm's natural one, while a pinch may
            // go anywhere legible glyphs still exist.
            let base = min(naturalFontSize, max(FontSize.readable, fit))
            let target = min(FontSize.max, max(FontSize.min, base * zoom))

            guard abs(target - point) > 0.05 else { return }
            applyFont(ofSize: target)
        }
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began, .changed:
            zoom = min(6, max(0.25, zoom * gesture.scale))
            gesture.scale = 1
            // Invalidated so the next pass refits with the new multiplier;
            // `setNeedsLayout` is safe here because a gesture is not inside a
            // layout pass, so it schedules one rather than re-entering it.
            fitted = nil
            view.setNeedsLayout()
        default:
            break
        }
    }

    /// Swaps the font, keeping the column count fixed, and re-measures.
    ///
    /// **The frame is corrected in the same breath, and that is the whole
    /// point.** `TerminalView` derives its columns from `bounds.width /
    /// cellWidth`, so a new font against the old frame is a different number of
    /// columns — and SwiftTerm reflows its buffer whenever that changes. An
    /// intermediate reflow at a width nobody asked for cuts the text, and
    /// `observe` sends a full redraw only when the stream opens, so nothing
    /// repairs it. Setting both together means the column count never moves.
    ///
    /// `layoutIfNeeded` on the terminal rather than `setNeedsLayout` on the
    /// controller: SwiftTerm recomputes `cellDimension` in its own
    /// `layoutSubviews`, and every caller here measures right afterwards.
    private func applyFont(ofSize size: CGFloat) {
        terminalView.font = UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
        // `cellDimension` is updated synchronously by the setter's `resetFont`,
        // so the new cell is already measurable here.
        if let grid, let cell = cellSize() {
            terminalView.frame = CGRect(origin: .zero, size: frameSize(for: grid, cell: cell))
        }
        terminalView.layoutIfNeeded()
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
        let size = frameSize(for: grid, cell: cell)
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

    /// The frame that yields exactly `grid` columns and rows.
    ///
    /// Landing exactly on `cols * cellWidth` would put `TerminalView`'s own
    /// `Int(width / cellWidth)` on a boundary where an error of one ulp costs a
    /// whole column, and a terminal one column narrower than the stream feeding
    /// it wraps every line. Rounding up and adding half a point clears the
    /// boundary by far more than any float error and far less than a cell.
    private func frameSize(for grid: TerminalGrid, cell: CGSize) -> CGSize {
        CGSize(
            width: (cell.width * CGFloat(grid.cols)).rounded(.up) + 0.5,
            height: (cell.height * CGFloat(grid.rows)).rounded(.up) + 0.5
        )
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
