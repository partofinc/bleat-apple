#if canImport(UIKit)
import BleatKit
import SwiftUI
import Testing
import UIKit
@testable import BleatUI

/// What the pane actually measures at a given screen size.
///
/// **This exists because looking at a phone was the only check.** Several
/// sizing bugs on this screen — a font fit that froze the app in a layout loop,
/// a terminal reflowed at a width nobody asked for, a pty grown past the pane's
/// rect — all shipped past a green test run, because nothing mechanical ever
/// laid this view out. Now something does.
@Suite("Pane geometry", .serialized)
@MainActor
struct PaneGeometryTests {

    /// Lays the controller out at a given size and reports what it derived.
    private func measure(width: CGFloat, height: CGFloat) -> (grid: TerminalGrid?, frame: CGSize, font: CGFloat) {
        let controller = PaneTerminalController()
        var reported: TerminalGrid?
        controller.onSize = { reported = $0 }
        // Forces `viewDidLoad`, then a real layout pass at this size.
        controller.view.frame = CGRect(x: 0, y: 0, width: width, height: height)
        controller.view.layoutIfNeeded()
        return (reported, controller.terminalFrameForTesting, controller.fontSizeForTesting)
    }

    /// iPhone 15 Pro portrait, less the navigation bar. SwiftTerm's default
    /// font is 12pt with a cell about 7.2pt wide, so this should be about 54
    /// columns — and crucially the terminal must *fill* the view it was given.
    @Test("portrait fills the view and derives its own grid")
    func portrait() {
        let result = measure(width: 393, height: 700)
        let grid = result.grid
        #expect(grid?.isUsable == true)
        #expect(result.frame.width == 393)
        #expect(result.frame.height == 700)
        // The font is never changed any more: the pane is resized to the phone
        // rather than the type to the pane.
        #expect(result.font == 12)
        #expect((50...56).contains(grid?.cols ?? 0), "expected ~54 columns, got \(grid?.cols ?? -1)")
    }

    /// The case that looked wrong on device: a terminal that did not fill the
    /// width, at a font that was not 12pt.
    @Test("landscape fills the view and derives its own grid")
    func landscape() {
        let result = measure(width: 852, height: 330)
        let grid = result.grid
        #expect(result.frame.width == 852)
        #expect(result.font == 12)
        #expect((110...125).contains(grid?.cols ?? 0), "expected ~118 columns, got \(grid?.cols ?? -1)")
        #expect((20...24).contains(grid?.rows ?? 0), "expected ~22 rows, got \(grid?.rows ?? -1)")
    }

    /// **The regression test for an endless spinner.**
    ///
    /// `PaneKeyBar` lives in the bottom safe area, and this terminal derives its
    /// grid from its own bounds — so anything that shows or hides the bar
    /// resizes the terminal, which reports a new grid, which reopens the stream.
    /// Gating the bar on `phase == .live` therefore closed a loop: bar shows →
    /// terminal shrinks → reopen → `.opening` → bar hides → terminal grows →
    /// reopen → `.live`, forever, `stty`-ing the user's Mac each time round. It
    /// reached a device.
    ///
    /// The invariant that stops it: **the layout must be the same in every
    /// phase.** Anything drawn per-phase has to be an overlay or
    /// `.disabled`, neither of which is layout.
    @Test("the chrome does not resize the terminal between phases")
    func chromeIsStableAcrossPhases() {
        // In a **key window**, for the reason `PreviewSmokeTests.render` uses
        // one: a hosting controller merely given a frame evaluates the body but
        // never appears, so the representable's child controller never lays out
        // and reports no grid at all.
        func viewport(inPhase phase: PaneModel.Phase) -> TerminalGrid? {
            let model = PaneModel(previewing: phase)
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 759))
            window.rootViewController = UIHostingController(
                rootView: PaneSurface(model: model, isActive: true)
            )
            window.makeKeyAndVisible()
            window.layoutIfNeeded()
            return model.viewportForTesting
        }

        let live = viewport(inPhase: .live)
        #expect(live?.isUsable == true, "the terminal never laid out")
        // The two phases the loop alternated between.
        #expect(viewport(inPhase: .opening) == live)
        // And the ones a failure can settle in, since each draws its own
        // `ContentUnavailableView` over the terminal.
        #expect(viewport(inPhase: .ended) == live)
        #expect(viewport(inPhase: .failed("lost it")) == live)
    }

    /// **The keyboard must not resize somebody's agent.**
    ///
    /// This terminal derives its grid from its own bounds and the pane's pty is
    /// `stty`'d to match, so a keyboard covering half the screen would take the
    /// pane from ~46 rows to ~24 on the way up and put it back on the way down
    /// — reflowing a live Claude Code on the user's Mac every time a phone user
    /// tapped a key. So the grid is frozen and the terminal is *translated*
    /// instead, bottom-anchored above the keyboard with its top clipped.
    @Test("raising the keyboard does not change the grid")
    func keyboardFreezesTheGrid() {
        let controller = PaneTerminalController()
        var reports: [TerminalGrid] = []
        controller.onSize = { reports.append($0) }
        controller.view.frame = CGRect(x: 0, y: 0, width: 393, height: 700)
        controller.view.layoutIfNeeded()

        let before = reports.last
        #expect(before?.isUsable == true, "the terminal never laid out")
        #expect(reports.count == 1)

        controller.wantsKeyboard = true
        // What is left of the screen with a keyboard over it.
        controller.view.frame = CGRect(x: 0, y: 0, width: 393, height: 380)
        controller.view.layoutIfNeeded()

        #expect(
            reports.count == 1,
            "the keyboard reported \(reports.count - 1) new grid(s): \(reports.dropFirst())"
        )
    }

    /// **A shell's prompt must stay on screen under the keyboard.** The frozen
    /// terminal used to be pinned by its bottom edge, which suits an agent —
    /// its input box is the last thing it draws — and slid a shell with three
    /// lines in it clean off the top, prompt included.
    @Test("a prompt near the top stays put when the keyboard comes up")
    func keyboardKeepsAShortShellOnScreen() {
        let controller = PaneTerminalController()
        controller.view.frame = CGRect(x: 0, y: 0, width: 393, height: 700)
        controller.view.layoutIfNeeded()
        controller.feedForTesting(Data("\u{1B}[1;1H$ ls\u{1B}[2;1Hfile\u{1B}[3;1H$ ".utf8))

        controller.wantsKeyboard = true
        controller.view.frame = CGRect(x: 0, y: 0, width: 393, height: 380)
        controller.view.layoutIfNeeded()

        #expect(controller.terminalOriginForTesting == 0, "the prompt was slid off the top")
        #expect(controller.terminalFrameForTesting.height == 700)
    }

    /// The case the old rule was right about: a screen drawn to the bottom.
    @Test("a full screen is pinned by its bottom edge")
    func keyboardPinsAFullScreenToTheBottom() {
        let controller = PaneTerminalController()
        var grid: TerminalGrid?
        controller.onSize = { grid = $0 }
        controller.view.frame = CGRect(x: 0, y: 0, width: 393, height: 700)
        controller.view.layoutIfNeeded()
        let rows = grid?.rows ?? 0
        #expect(rows > 0)
        // An agent's status line: something on the very last row, with the
        // cursor parked well above it.
        controller.feedForTesting(Data("\u{1B}[\(rows);1Hstatus\u{1B}[5;1H".utf8))

        controller.wantsKeyboard = true
        controller.view.frame = CGRect(x: 0, y: 0, width: 393, height: 380)
        controller.view.layoutIfNeeded()

        // Within a pixel: UIKit stores the frame as a centre and bounds, and
        // the origin read back is not bit-for-bit the one that was set.
        #expect(abs(controller.terminalOriginForTesting - (380 - 700)) < 0.5)
    }

    /// Output moves the prompt down, and the terminal has to follow it.
    @Test("the terminal follows the prompt as output pushes it down")
    func keyboardFollowsThePrompt() {
        let controller = PaneTerminalController()
        var grid: TerminalGrid?
        controller.onSize = { grid = $0 }
        controller.view.frame = CGRect(x: 0, y: 0, width: 393, height: 700)
        controller.view.layoutIfNeeded()
        let rows = grid?.rows ?? 0
        controller.feedForTesting(Data("\u{1B}[1;1H$ ".utf8))

        controller.wantsKeyboard = true
        controller.view.frame = CGRect(x: 0, y: 0, width: 393, height: 380)
        controller.view.layoutIfNeeded()
        #expect(controller.terminalOriginForTesting == 0)

        // The prompt, now most of the way down the pane.
        controller.feedForTesting(Data("\u{1B}[\(rows - 4);1H$ ".utf8))
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()

        let y = controller.terminalOriginForTesting
        #expect(y < 0, "the prompt went under the keyboard and the terminal stayed put")
        #expect(y > 380 - 700, "it moved further than the prompt needed")
        // Whole points, so the text is not drawn between pixels.
        #expect(abs(y - y.rounded()) < 0.01, "the terminal sits at a fractional offset: \(y)")
    }

    /// And the way back down reports nothing either — which is the half that is
    /// easy to get wrong. Unfreezing on `willHide` rather than `didHide` would
    /// report a grid per frame of the dismissal animation, and every one of
    /// those is a stream reopen and a write to the user's Mac.
    @Test("dismissing the keyboard does not reopen the stream")
    func dismissingRestoresTheGridQuietly() {
        let controller = PaneTerminalController()
        var reports: [TerminalGrid] = []
        controller.onSize = { reports.append($0) }
        controller.view.frame = CGRect(x: 0, y: 0, width: 393, height: 700)
        controller.view.layoutIfNeeded()
        let before = reports.last

        controller.wantsKeyboard = true
        controller.view.frame = CGRect(x: 0, y: 0, width: 393, height: 380)
        controller.view.layoutIfNeeded()

        controller.wantsKeyboard = false
        NotificationCenter.default.post(
            name: UIResponder.keyboardDidHideNotification, object: nil
        )
        controller.view.frame = CGRect(x: 0, y: 0, width: 393, height: 700)
        controller.view.layoutIfNeeded()

        // The grid it comes back to is the one it left, so `report`'s own
        // de-duplication swallows it and nothing downstream ever hears.
        #expect(reports.count == 1, "the round trip reported \(reports.count) grids")
        #expect(reports.last == before)
    }

    /// **The text field's keyboard takes the same half of the screen.** The
    /// terminal never asked for this one — `wantsKeyboard` stays false — so the
    /// freeze has to come from the keyboard itself, or tapping the field in
    /// `PaneKeyBar` resizes the pane the way typing into the terminal once did.
    @Test("a keyboard the terminal did not ask for freezes the grid too")
    func anotherKeyboardFreezesTheGrid() {
        let controller = PaneTerminalController()
        var reports: [TerminalGrid] = []
        controller.onSize = { reports.append($0) }
        controller.view.frame = CGRect(x: 0, y: 0, width: 393, height: 700)
        controller.view.layoutIfNeeded()
        #expect(reports.count == 1)

        NotificationCenter.default.post(
            name: UIResponder.keyboardWillShowNotification, object: nil
        )
        controller.view.frame = CGRect(x: 0, y: 0, width: 393, height: 380)
        controller.view.layoutIfNeeded()
        #expect(reports.count == 1, "the field's keyboard reported a new grid: \(reports.dropFirst())")

        NotificationCenter.default.post(
            name: UIResponder.keyboardDidHideNotification, object: nil
        )
        controller.view.frame = CGRect(x: 0, y: 0, width: 393, height: 700)
        controller.view.layoutIfNeeded()
        #expect(reports.count == 1, "the round trip reported \(reports.count) grids")

        // And it let go: a genuinely different height is reported again.
        controller.view.frame = CGRect(x: 0, y: 0, width: 393, height: 600)
        controller.view.layoutIfNeeded()
        #expect(reports.count == 2, "the grid stayed frozen after the keyboard went")
    }

    /// **The accessory is one height whatever it holds.** It sits in a
    /// safe-area bar, so its height is the terminal's, and the terminal's is
    /// the grid the pane on someone's Mac is `stty`'d to. A text field a point
    /// taller than the shortcut strip would resize their pane every time the
    /// mode menu was used.
    @Test("the accessory is the same height in every mode")
    func accessoryHeightIsConstant() {
        let key = "pane.accessoryMode"
        let saved = UserDefaults.standard.string(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }

        func height(_ mode: PaneAccessoryMode, typingInPane: Bool = false) -> CGFloat {
            UserDefaults.standard.set(mode.rawValue, forKey: key)
            let model = PaneModel(previewing: .live)
            model.setWantsKeyboard(typingInPane)
            let host = UIHostingController(rootView: PaneKeyBar(model: model, isActive: true))
            return host.sizeThatFits(in: CGSize(width: 393, height: 800)).height
        }

        let field = height(.input)
        #expect(field > 80, "the accessory did not lay out two rows: \(field)")
        #expect(height(.shortcuts) == field)
        #expect(height(.input, typingInPane: true) == field)
    }

    /// **`keyboardDidHide` cannot be the only way out of the freeze.** With a
    /// hardware keyboard attached no software keyboard appears, so the
    /// notification never arrives — and SwiftTerm's accessory bar, which might
    /// otherwise put one on screen, has been removed. The grid would then stay
    /// frozen for the life of the screen, so a later rotation would report
    /// nothing and the stream and the pane's pty would sit at a size the view
    /// no longer is.
    ///
    /// No notification is posted anywhere in this test, which is the point.
    @Test("the grid thaws even when no keyboard ever appeared")
    func thawsWithoutAKeyboard() {
        let controller = PaneTerminalController()
        var reports: [TerminalGrid] = []
        controller.onSize = { reports.append($0) }
        controller.view.frame = CGRect(x: 0, y: 0, width: 393, height: 700)
        controller.view.layoutIfNeeded()
        #expect(reports.count == 1)

        controller.wantsKeyboard = true
        controller.view.frame = CGRect(x: 0, y: 0, width: 393, height: 381)
        controller.view.layoutIfNeeded()
        #expect(reports.count == 1, "the freeze did not hold")

        controller.wantsKeyboard = false
        // A genuinely different height, so a report here can only mean the
        // terminal is sizing itself to the view again.
        controller.view.frame = CGRect(x: 0, y: 0, width: 393, height: 600)
        controller.view.layoutIfNeeded()
        #expect(reports.count == 2, "the grid stayed frozen with no keyboard to hide")
    }

    /// **A rotation thaws it**, because the frozen size holds the width too.
    /// Turning the device with the keyboard up would otherwise draw a
    /// 393pt-wide terminal inside an 852pt view — a strip down one side with
    /// black beside it — and nothing would correct it until the keyboard went
    /// down.
    @Test("rotating with the keyboard up gives up the frozen width")
    func rotationThawsTheFreeze() {
        let controller = PaneTerminalController()
        var reports: [TerminalGrid] = []
        controller.onSize = { reports.append($0) }
        controller.view.frame = CGRect(x: 0, y: 0, width: 393, height: 700)
        controller.view.layoutIfNeeded()

        controller.wantsKeyboard = true
        controller.view.frame = CGRect(x: 0, y: 0, width: 393, height: 381)
        controller.view.layoutIfNeeded()
        let frozen = reports.count

        controller.view.frame = CGRect(x: 0, y: 0, width: 852, height: 330)
        controller.view.layoutIfNeeded()
        #expect(
            reports.count > frozen,
            "the terminal kept its portrait width in landscape"
        )
        #expect((110...125).contains(reports.last?.cols ?? 0), "got \(reports.last?.cols ?? -1) columns")
    }

    /// Rotation must produce a *different* grid, or nothing downstream reopens
    /// the stream and the screen keeps frames drawn for the old shape.
    @Test("rotating changes the reported grid")
    func rotationChangesTheGrid() {
        let portrait = measure(width: 393, height: 700).grid
        let landscape = measure(width: 852, height: 330).grid
        #expect(portrait != landscape)
    }
}
#endif
