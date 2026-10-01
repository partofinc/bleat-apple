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
///
/// **The one exception to "it sizes itself" is the keyboard**, which would
/// otherwise resize the user's pane every time it appeared. See
/// `wantsKeyboard`.
final class PaneTerminalController: UIViewController {
    /// The grid the terminal is showing, whenever it changes. Both "what to ask
    /// the host for" and "what the stream is being rendered at" — they are the
    /// same number now, which is why there is one callback instead of two.
    var onSize: ((TerminalGrid) -> Void)?
    /// How tall the terminal draws a row, alongside every size report. Not
    /// part of `onSize` because it is not a size anything is asked for: it is
    /// only what the scroll gesture measures a finger against.
    var onRowHeight: ((CGFloat) -> Void)?
    /// Called once, with the view ready to be fed.
    var onReady: ((TerminalView) -> Void)?
    /// What the keyboard produced, byte for byte, on its way to the host.
    var onInput: ((Data) -> Void)?

    /// Whether the keyboard should be up.
    ///
    /// **Setting this freezes the grid, and that is the whole reason it is a
    /// property rather than a `becomeFirstResponder()` at the call site.** The
    /// keyboard covers something like half the screen, and this terminal
    /// derives its columns and rows from its own bounds — which are then
    /// `stty`'d onto the pane. Left alone, raising the keyboard would resize
    /// somebody's live agent from ~46 rows to ~24 and put it back on dismissal,
    /// every single time. Reflowing a person's Claude Code because a phone user
    /// tapped a key is not a trade worth making.
    ///
    /// So the terminal is **translated, not resized**: it keeps its full frozen
    /// height and slides up under the navigation bar, its top clipped by the
    /// view. The grid never changes and nothing is written to the host. How
    /// far it slides is `KeyboardAnchor`'s business: far enough to keep the
    /// last row in use on screen — an agent's input box at the bottom, or a
    /// shell's prompt wherever it has got to — and no further.
    var wantsKeyboard = false {
        didSet {
            guard wantsKeyboard != oldValue else { return }
            if wantsKeyboard {
                // Frozen *before* the keyboard animates in, so no intermediate
                // size is ever reported. Unfreezing waits for `keyboardDidHide`
                // — unfreezing on the way down would report a grid per frame of
                // the dismissal animation, and each one is a stream reopen.
                frozen = terminalView.frame.size
                terminalView.acceptsKeyboard = true
                _ = terminalView.becomeFirstResponder()
            } else {
                // Drops first responder via `acceptsKeyboard`'s own `didSet`.
                terminalView.acceptsKeyboard = false
                // If no software keyboard was ever up there is no `didHide`
                // coming, so this is the only chance to thaw.
                thawIfIdle()
            }
        }
    }

    /// The size the terminal is held at while the keyboard is up. `nil` means
    /// it may size itself to the view again.
    private var frozen: CGSize?

    /// How many repaint passes SwiftTerm has run, for `PaneRepaintTests`.
    private(set) var repaints = 0

    /// Where the drawn viewport sits relative to the live screen. Equal means
    /// the terminal is showing the bottom — what herdr is actually painting.
    var scrollStateForTesting: (position: Double, canScroll: Bool) {
        (terminalView.scrollPosition, terminalView.canScroll)
    }

    /// Feeds bytes as if they had come off the stream. Tests only.
    func feedForTesting(_ data: Data) {
        terminalView.feed(byteArray: ArraySlice(data))
    }

    /// Takes the keyboard only when `wantsKeyboard` says so; renders always.
    private lazy var terminalView = PaneTerminalView(frame: .zero, font: nil)
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
        // work — but a stream frame never scrolls the terminal, so nothing
        // is ever pushed into `TerminalView`'s buffer. Measured 6 Sept 2026: a
        // frame is 3.6KB of absolute cursor positioning (`ESC[19;3H`) and SGR
        // colour, with **zero newlines and zero carriage returns**. Lines are
        // painted in place; none scroll off.
        //
        // What does work is asking the host: `terminal.scroll` makes herdr
        // repaint the pane scrolled, which is what `PaneScrollGesture` sends.
        //
        // **And no setting here can change that**, which is worth stating
        // because it is the obvious place to look. Measured 8 Sept 2026 on a
        // pane that had genuinely scrolled — `seq 1 200` through 30 rows, 172
        // rows of scrollback on the host — the stream still sent four frames of
        // exactly 30 rows with **LF=0 and CR=0 in every one**. Herdr renders
        // its own buffer and ships absolute positioning, so nothing is pushed
        // off the top here and this buffer stays empty by construction. Not a
        // sizing problem, not a SwiftTerm option.
        //
        // History, where a pane has any, comes from `pane read` instead
        // (`HerdrClient.paneText`). An agent's pane usually has none even
        // there: its TUI is on the alternate screen, whose rows never enter
        // herdr's scrollback. What holds an agent's history is its transcript,
        // which is what chat mode reads.
        //
        // **So this is off**, and that is what frees the drag. It was left on
        // for a while on the theory that a program which did scroll would then
        // work — but nothing can, so all it did was consume every vertical
        // swipe on behalf of an empty buffer. With it off, `PaneScrollGesture`
        // gets the drag and turns it into `terminal.scroll` requests.
        terminalView.isScrollEnabled = false

        // **Taking the keyboard re-arms mouse reporting, and that undoes the
        // "a button, not a tap on the pane" rule.** SwiftTerm gates its tap and
        // pan handlers on `isFirstResponder`, and `allowMouseReporting`
        // defaults to true — so once the pane can be typed into, a tap on it
        // sends a mouse press to any program that has enabled mouse mode. On an
        // agent sitting at a dialog that is a click on one of its buttons.
        terminalView.allowMouseReporting = false
        // Turns on `rangeChanged`, which is off by default. It is the only
        // hook that proves a repaint pass ran; one delegate call per repaint.
        terminalView.notifyUpdateChanges = true

        // **The keys live in the safe area, not on the keyboard.** SwiftUI's
        // keyboard avoidance already lifts a `safeAreaBar` clear of the
        // keyboard, so `PaneKeyBar` stays where it is and rides up with it —
        // which keeps it a thumb's reach from the arrows rather than stranded
        // at the far edge of the screen, and removes an entire second copy of
        // the bar. What has to go is SwiftTerm's own accessory, or its keys and
        // ours are both on screen.
        terminalView.dropBuiltInAccessory()

        // Read off the **layer**, not `nativeBackgroundColor`: SwiftTerm's
        // `setupOptions` moves the real colour into `layer.backgroundColor` and
        // sets that property to `UIColor.clear`, so asking the obvious thing
        // paints a transparent band — white under a black terminal in light
        // mode.
        view.backgroundColor = terminalView.layer.backgroundColor.map(UIColor.init(cgColor:))
        // The frozen terminal is taller than this view while the keyboard is
        // up, and the overhang is meant to be hidden rather than drawn over the
        // navigation bar.
        view.clipsToBounds = true
        view.addSubview(terminalView)

        // **`didHide`, not `willHide`.** Unfreezing while the keyboard is still
        // animating away reports a new grid on every frame of it, and every one
        // of those is a stream reopen and an `stty` on the user's Mac. Waiting
        // until it has gone means exactly one layout pass, which reports the
        // grid the terminal had before any of this — so `report`'s own
        // de-duplication swallows it and nothing reopens at all.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardDidHide),
            name: UIResponder.keyboardDidHideNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardDidShow),
            name: UIResponder.keyboardDidShowNotification,
            object: nil
        )
    }

    @objc private func keyboardDidShow() { keyboardIsUp = true }

    @objc private func keyboardDidHide() {
        keyboardIsUp = false
        thawIfIdle()
    }

    /// Lets the terminal size itself again, once nothing is holding it.
    ///
    /// **`keyboardDidHide` cannot be the only way out.** With a hardware
    /// keyboard attached no software keyboard appears, so no notification ever
    /// arrives — and `dropBuiltInAccessory()` has removed the accessory that
    /// would otherwise be shown, so there is not even a bar to post one. The
    /// grid would then stay frozen for the life of the screen: rotation would
    /// report nothing, and the stream and the pane's pty would sit at a size
    /// the view no longer is.
    private func thawIfIdle() {
        guard frozen != nil, !wantsKeyboard, !keyboardIsUp else { return }
        frozen = nil
        view.setNeedsLayout()
    }

    /// Whether a software keyboard is actually on screen.
    private var keyboardIsUp = false

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard view.bounds.width > 0, view.bounds.height > 0 else { return }
        // **A rotation thaws it.** The frozen size holds the width as well as
        // the height, so turning the device with the keyboard up would draw a
        // 393pt-wide terminal inside an 852pt view — a strip down one side with
        // black beside it, and nothing to correct it until the keyboard went
        // down. Letting go costs one reopen, which is what a rotation costs
        // anyway, and is much the better of the two.
        if let held = frozen, held.width != view.bounds.width {
            frozen = nil
        }
        if let frozen {
            // At its frozen size: the keyboard takes the space and the terminal
            // slides up under the navigation bar, only as far as it takes to
            // keep the row being typed into on screen. `clipsToBounds` on the
            // view is what hides the rows that go.
            terminalView.frame = CGRect(
                x: 0,
                y: anchor(for: frozen),
                width: frozen.width,
                height: frozen.height
            )
        } else {
            terminalView.frame = view.bounds
        }
        // `TerminalView` recomputes its cols and rows in its own
        // `layoutSubviews`, which runs *after* this method — so without forcing
        // it, the size read below is `TerminalOptions`' default 80x25, a size
        // the view cannot show and the host would be asked for anyway.
        terminalView.layoutIfNeeded()

        let terminal = terminalView.getTerminal()
        if isActive { report(TerminalGrid(cols: terminal.cols, rows: terminal.rows)) }
        // The terminal's own figure. It was `view.bounds` over the rows, and
        // under the keyboard the bounds halve while the rows are frozen — which
        // is what made a drag scroll twice too fast while typing.
        onRowHeight?(rowHeight)

        if !announced {
            announced = true
            onReady?(terminalView)
        }
    }

    /// Where the frozen terminal sits under the keyboard.
    private func anchor(for frozen: CGSize) -> CGFloat {
        KeyboardAnchor.offset(
            visible: view.bounds.height,
            terminal: frozen.height,
            rowHeight: rowHeight,
            lastRow: lastRowInUse
        )
    }

    /// The height SwiftTerm draws a row at.
    ///
    /// **Recomputed, because SwiftTerm keeps its own internal** — this is
    /// `computeFontDimensions`, line for line: the font's ascent, descent and
    /// leading, rounded up. The frame's height over the row count is not the
    /// same number: SwiftTerm takes `Int(height / cellHeight)` rows and leaves
    /// the remainder as a strip at the bottom, so that quotient is a fraction
    /// of a point too large. If SwiftTerm's line spacing is ever changed from
    /// its default of 1, this has to follow.
    private var rowHeight: CGFloat {
        let font = terminalView.font as CTFont
        return ceil(CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font))
    }

    /// The lowest row with anything on it, or the cursor's if that is lower.
    ///
    /// **Both, because neither is enough alone.** A shell's prompt is where
    /// the cursor is, and on an empty line there is nothing else to find. An
    /// agent may park its cursor in an input box with status lines beneath it,
    /// or hide it and leave it anywhere; what marks the bottom of its screen
    /// is the last row it drew.
    private var lastRowInUse: Int {
        let terminal = terminalView.getTerminal()
        let cursor = terminal.getCursorLocation().y
        for row in stride(from: terminal.rows - 1, to: cursor, by: -1) {
            guard let line = terminal.getLine(row: row) else { continue }
            // herdr paints blank cells as spaces as readily as it skips them,
            // so "has content" has to mean something visible.
            let drawn = line.translateToString(trimRight: true)
                .contains { !$0.isWhitespace && $0 != "\0" }
            if drawn { return row }
        }
        return max(cursor, 0)
    }

    /// Read by `BleatUITests`: where the terminal sits in its view, which is
    /// what decides whether the prompt is on screen under the keyboard.
    var terminalOriginForTesting: CGFloat { terminalView.frame.origin.y }

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
        // Straight through, unexamined. These are the bytes a terminal would
        // have sent, escape sequences and all, and `PaneModel` drops them when
        // there is no stream to carry them — which is the only gate that
        // belongs on them. Filtering here would break the very sequences an
        // agent's UI is driven by.
        onInput?(Data(data))
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

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {
        // Fires from inside SwiftTerm's `updateDisplay`, so it is the only
        // observable proof from out here that a repaint pass actually ran.
        repaints += 1
        // Under the keyboard the terminal follows the last row in use, and
        // output is what moves that: a command that prints ten lines takes the
        // prompt ten rows down. Only the origin changes, so nothing is reported
        // and nothing reopens.
        //
        // Compared within a pixel: the origin UIKit hands back is not
        // bit-for-bit the one it was given, and an exact test asked for a
        // layout pass on every repaint.
        if let frozen, abs(anchor(for: frozen) - terminalView.frame.origin.y) > 0.5 {
            view.setNeedsLayout()
        }
    }
}
#endif
