#if canImport(UIKit)
import BleatKit
import SwiftUI
import SwiftTerm

/// SwiftTerm's terminal, as a SwiftUI view.
struct TerminalHost: UIViewControllerRepresentable {
    let model: PaneModel
    /// Passed in from the view body rather than read off the model in
    /// `updateUIViewController`, so SwiftUI actually observes it: a
    /// representable's update runs when its *parent* re-renders, and a
    /// dependency read only inside `updateUIViewController` never triggers one.
    let grid: TerminalGrid?

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
        controller.onViewport = { [model] viewport in
            // The fallback size, and the thing that starts the stream. What the
            // host is asked to render at is the *pane's* grid wherever it will
            // report one — see `PaneModel.open`.
            model.open(viewport: viewport)
        }
        controller.onGridApplied = { [model] applied in
            // Frames are held until this arrives: SwiftUI publishes the grid an
            // async hop before the view resizes to it, and the first frame lands
            // in that window.
            model.gridApplied(applied)
        }
        controller.grid = grid
        return controller
    }

    func updateUIViewController(_ controller: PaneTerminalController, context: Context) {
        controller.grid = grid
    }
}
#endif
