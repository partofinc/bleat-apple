#if canImport(UIKit) && !os(watchOS)
import BleatKit
import SwiftUI
import SwiftTerm

/// SwiftTerm's terminal, as a SwiftUI view.
struct TerminalHost: UIViewControllerRepresentable {
    let model: PaneModel
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
