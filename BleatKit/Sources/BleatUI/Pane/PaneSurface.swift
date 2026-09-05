import SwiftUI

/// The terminal itself, with whatever needs saying over it.
///
/// On a platform without SwiftTerm's UIKit view there is no surface, and saying
/// so beats a blank rectangle — `BleatUI` builds for macOS as well, where the
/// app does not exist yet.
struct PaneSurface: View {
    let model: PaneModel

    var body: some View {
        #if canImport(UIKit)
        TerminalHost(model: model)
            .ignoresSafeArea(.container, edges: .bottom)
            .overlay {
                switch model.phase {
                case .opening:
                    ProgressView()
                case .live:
                    EmptyView()
                case .ended:
                    ContentUnavailableView(
                        "The pane closed",
                        systemImage: "rectangle.slash",
                        description: Text("Herdr stopped sending frames for it.")
                    )
                case .failed(let message):
                    ContentUnavailableView(
                        "Lost the pane",
                        systemImage: "exclamationmark.triangle",
                        description: Text(message)
                    )
                }
            }
        #else
        ContentUnavailableView(
            "No terminal here",
            systemImage: "rectangle.slash",
            description: Text("The pane view is iOS-only for now.")
        )
        #endif
    }
}
