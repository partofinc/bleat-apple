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
    /// Whether this terminal is the one on screen.
    ///
    /// It stays mounted while the chat is showing, so that switching back is
    /// instant — but a hidden view still lays out, and reporting a size from
    /// one would reopen a stream and `stty` someone's Mac for a view nobody is
    /// looking at.
    var isActive = true {
        didSet { if isActive, isActive != oldValue { view.setNeedsLayout() } }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        terminalView.terminalDelegate = self
        // **There is no scrollback here, and there cannot be.** Left on
        // because it costs nothing and a program that does scroll would then
        // work — but an `observe` frame never scrolls the terminal, so nothing
        // is ever pushed into `TerminalView`'s buffer. Measured 6 Sept 2026: a
        // frame is 3.6KB of absolute cursor positioning (`ESC[19;3H`) and SGR
        // colour, with **zero newlines and zero carriage returns**. Lines are
        // painted in place; none scroll off.
        //
        // Asking the host to scroll instead does not work either: `observe`
        // ignores `terminal.scroll` — sent one, got a single frame and nothing
        // on stderr, not even an "input ignored".
        //
        // **And there is none on the host either, for these panes.** Measured
        // 8 Sept 2026: `pane list` reports `max_offset_from_bottom: 0` for
        // every pane of a real session, and `pane read --source recent` returns
        // exactly the visible rows. An agent's TUI runs on the alternate
        // screen, which has no scrollback by definition — its buffer is the
        // viewport. So this is not a client limitation to work around; the
        // history of an agent pane is its transcript, which is what chat mode
        // reads.
        terminalView.isScrollEnabled = true
        terminalView.getTerminal().changeHistorySize(1500)

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
        if isActive { report(TerminalGrid(cols: terminal.cols, rows: terminal.rows)) }

        if !announced {
            announced = true
            onReady?(terminalView)
        }
    }

    /// Read by `BleatUITests` to check the terminal really fills its view —
    /// the thing that has to be true and was only ever eyeballed.
    var terminalFrameForTesting: CGSize { terminalView.frame.size }
    var fontSizeForTesting: CGFloat { terminalView.font.pointSize }

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
        // **Not reported directly, because this is not only the view's
        // geometry.** SwiftTerm fires it from `processSizeChange`, but also on
        // DECCOLM — `ESC[?3h`/`ESC[?3l` — once a pane has sent `ESC[?40h` to
        // allow 80/132 switching. Bytes printed inside the remote pane could
        // then drive a stream reopen *and* an `stty` against the user's Mac,
        // which is remote content reaching a host write.
        //
        // Asking for a layout pass instead re-derives the size from this view's
        // own bounds, so the answer can only ever come from the phone.
        view.setNeedsLayout()
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
