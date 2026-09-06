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
        TerminalHost(model: model, grid: model.grid)
            .ignoresSafeArea(.container, edges: .bottom)
            .overlay(alignment: .bottomTrailing) {
                if case .live = model.phase, let grid = model.grid {
                    GridBadge(grid: grid, paneGrid: model.paneGrid)
                }
            }
            .overlay {
                switch model.phase {
                case .opening:
                    ProgressView()
                case .live:
                    EmptyView()
                case .ended:
                    ContentUnavailableView {
                        Label("The pane closed", systemImage: "rectangle.slash")
                    } description: {
                        Text("Herdr stopped sending frames for it.")
                    } actions: {
                        Button("Try again", action: model.retry)
                    }
                case .failed(let message):
                    // A dropped socket is normal on a phone — CLAUDE.md says so
                    // — and every other screen offers a way back from one. A
                    // pane that could only be revived by popping and pushing
                    // the screen again was the odd one out.
                    ContentUnavailableView {
                        Label("Lost the pane", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Try again", action: model.retry)
                    }
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
