#if canImport(UIKit)
import BleatKit
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
