#if canImport(UIKit)
import SwiftUI
import SwiftTerm

/// SwiftTerm's terminal, as a SwiftUI view.
struct TerminalHost: UIViewControllerRepresentable {
    let model: PaneModel

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
        controller.onSize = { [model] cols, rows in
            model.open(cols: cols, rows: rows)
        }
        return controller
    }

    func updateUIViewController(_ controller: PaneTerminalController, context: Context) {}
}
#endif
