#if canImport(UIKit)
import SwiftTerm
import UIKit

/// Hosts SwiftTerm's `TerminalView` and reports the size it can actually show.
///
/// A view controller rather than a bare view for the layout hook: the number of
/// columns and rows depends on the frame and the font, so it is only knowable
/// after a layout pass — and it is what the host is asked to render at, so the
/// pane arrives already fitted to the phone rather than needing to be scrolled
/// sideways.
final class PaneTerminalController: UIViewController {
    /// Called with the terminal's size whenever it changes, including the first
    /// time it is known.
    var onSize: ((Int, Int) -> Void)?
    /// Called once, with the view ready to be fed.
    var onReady: ((TerminalView) -> Void)?

    /// Read-only: it renders and scrolls, and it will not take the keyboard.
    private lazy var terminalView = ReadOnlyTerminalView(frame: .zero, font: nil)
    private var reported: (cols: Int, rows: Int)?
    private var announced = false

    override func viewDidLoad() {
        super.viewDidLoad()
        terminalView.terminalDelegate = self
        view.addSubview(terminalView)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        terminalView.frame = view.bounds
        // Laid out **now**, not next pass. `TerminalView` recomputes its cols
        // and rows in its own `layoutSubviews`, which runs after this method
        // returns — so reading the terminal here without forcing it reports
        // `TerminalOptions`' default 80×25 and opens the stream at a size the
        // view cannot show. Recovery would then depend on a second layout pass
        // happening at all.
        terminalView.layoutIfNeeded()

        if !announced {
            announced = true
            onReady?(terminalView)
        }
        let terminal = terminalView.getTerminal()
        report(cols: terminal.cols, rows: terminal.rows)
    }

    /// Deduplicated, because both the layout pass and the delegate report the
    /// same change and either may come first.
    private func report(cols: Int, rows: Int) {
        let size = (cols: cols, rows: rows)
        guard reported == nil || reported! != size else { return }
        reported = size
        onSize?(cols, rows)
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
        // when the *view's* geometry changes what fits. It is the authoritative,
        // correctly-timed answer to "how big is this terminal", and ignoring it
        // was how a wrong size could go uncorrected.
        report(cols: newCols, rows: newRows)
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
