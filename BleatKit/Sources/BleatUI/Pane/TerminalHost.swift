#if canImport(UIKit) && !os(watchOS)
import BleatKit
import SwiftUI
import SwiftTerm

/// SwiftTerm's terminal, as a SwiftUI view.
struct TerminalHost: UIViewControllerRepresentable {
    let model: any PaneDriving
    /// Whether the terminal is the mode on screen. Passed from the view body
    /// rather than read off the model, so SwiftUI observes it.
    let isActive: Bool
    /// Whether the keyboard should be up — **also passed in rather than read
    /// off the model**, for exactly the reason above. Nothing in
    /// `PaneSurface.body` reads `wantsKeyboard`, so flipping it invalidates
    /// only `PaneKeyBar`, a child whose re-render need not drive a
    /// representable update at all. Relying on that is relying on an accident.
    let wantsKeyboard: Bool

    func makeUIViewController(context: Context) -> PaneTerminalController {
        let controller = PaneTerminalController()
        controller.onReady = { [model] terminal in
            // Frames go in exactly as they arrived. `terminal.frame` payloads
            // carry cursor positioning and synchronized-output markers inside
            // the bytes, so anything that touched them would corrupt the screen.
            model.attach { [weak terminal] data in
                terminal?.feed(byteArray: ArraySlice(data))
            }
            // How a scroll reaches a program over hc, which has no scroll
            // command — the three cases a real terminal tells apart:
            //
            // - The program asked for the mouse (Claude Code): wheel clicks,
            //   encoded in the protocol it asked for, sent like any input.
            // - A full-screen program that did not (less, man, vim): the
            //   alternate screen keeps no history to scroll, so arrows, as
            //   xterm's alternate-scroll mode sends — in the program's cursor
            //   key mode, `ESC O A` once it has set DECCKM, as less does.
            // - Anything else (a shell): the history this terminal holds.
            model.attachScroller { [weak terminal, model] direction, notches in
                guard let terminal, notches > 0 else { return }
                let engine = terminal.getTerminal()
                if engine.mouseMode != .off {
                    let flags = engine.encodeButton(
                        button: direction == .up ? 4 : 5,
                        release: false, shift: false, meta: false, control: false
                    )
                    for _ in 0..<notches {
                        engine.sendEvent(buttonFlags: flags, x: engine.cols / 2, y: engine.rows / 2)
                    }
                } else if engine.isCurrentBufferAlternate {
                    let final: UInt8 = direction == .up ? 0x41 : 0x42      // A, B
                    let arrow = Data([0x1B, engine.applicationCursor ? 0x4F : 0x5B, final])
                    let bytes = Data(Array(repeating: arrow, count: notches).joined())
                    Task { await model.send(bytes: bytes) }
                } else if direction == .up {
                    terminal.scrollUp(lines: notches)
                } else {
                    terminal.scrollDown(lines: notches)
                }
            }
            // Whether several lines can go as one paste: the mode the program
            // set (`?2004h`), which hc's first paint restores.
            model.attachPasteMode { [weak terminal] in
                terminal?.getTerminal().bracketedPasteMode ?? false
            }
        }
        controller.isActive = isActive
        controller.onInput = { [model] data in
            Task { await model.send(bytes: data) }
        }
        controller.onSize = { [model] grid in
            // The terminal has sized itself to the screen. That is what the
            // host is asked to make the pane, and what the stream is opened at.
            model.show(grid)
        }
        controller.onRowHeight = { [model] height in
            model.setRowHeight(height)
        }
        return controller
    }

    func updateUIViewController(_ controller: PaneTerminalController, context: Context) {
        controller.isActive = isActive
        controller.wantsKeyboard = wantsKeyboard
    }
}
#endif

// No `#Preview`: without a stream this is an empty terminal, and everything
// worth looking at around it — the overlays, the failure states —
// previews in `PaneSurface`.
