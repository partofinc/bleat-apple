#if canImport(UIKit)
import BleatKit
import SwiftUI
import SwiftTerm

/// SwiftTerm's terminal, as a SwiftUI view.
struct TerminalHost: UIViewControllerRepresentable {
    let model: PaneModel
    /// Whether the terminal is the mode on screen. Passed from the view body
    /// rather than read off the model, so SwiftUI observes it.
    let isActive: Bool

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
        return controller
    }

    func updateUIViewController(_ controller: PaneTerminalController, context: Context) {
        controller.isActive = isActive
        // Read from the model rather than passed in, unlike `isActive`: nothing
        // above this needs to know, and the model is what `releaseControl()`
        // and `close()` clear it from.
        controller.wantsKeyboard = model.wantsKeyboard
    }
}
#endif

// No `#Preview`: without a stream this is an empty terminal, and everything
// worth looking at around it — the badge, the overlays, the failure states —
// previews in `PaneSurface`.
