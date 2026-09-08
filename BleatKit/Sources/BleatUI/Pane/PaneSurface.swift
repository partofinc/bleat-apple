import BleatKit
import SwiftUI

/// The terminal itself, with whatever needs saying over it.
///
/// On a platform without SwiftTerm's UIKit view there is no surface, and saying
/// so beats a blank rectangle — `BleatUI` builds for macOS as well, where the
/// app does not exist yet.
struct PaneSurface: View {
    let model: PaneModel
    let isActive: Bool

    var body: some View {
        #if canImport(UIKit)
        // **The safe area is respected, deliberately.** Extending under it
        // looked tidier — the terminal's black reaching the bottom of the glass
        // — but the pane's last row is its input line, and the home indicator
        // sits on top of it. A terminal's bottom row is the one that matters
        // most; there is nothing to gain by hiding it.
        TerminalHost(model: model, isActive: isActive)
            .background(.black)
            // Installed on the terminal itself rather than the whole surface,
            // so the buttons and the overlays keep their own taps.
            .paneScrollGesture(model)
            .overlay(alignment: .trailing) {
                // Only while this screen owns input, because these are the
                // only circumstances in which they can do anything: the keys
                // go to the program, and a pane this screen is merely watching
                // has nowhere to put them.
                if case .live = model.phase, model.control == .controlling {
                    PaneScrollControl(model: model)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if case .live = model.phase, let grid = model.grid {
                    GridBadge(grid: grid, isCropped: model.isCropped)
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

#if DEBUG
/// The terminal's own states. Three of the four are only reachable from a host
/// that stops answering, and each is a `ContentUnavailableView` over a black
/// terminal — which is a combination worth seeing before it happens on a phone.
#Preview("Live", traits: .sampleData) {
    PaneSurface(model: PaneModel(previewing: .live), isActive: true)
}

#Preview("Opening", traits: .sampleData) {
    PaneSurface(model: PaneModel(previewing: .opening), isActive: true)
}

/// Not a failure: herdr simply stopped sending frames, because the pane went
/// away or the session stopped.
#Preview("Ended", traits: .sampleData) {
    PaneSurface(model: PaneModel(previewing: .ended), isActive: true)
}

#Preview("Failed", traits: .sampleData) {
    PaneSurface(
        model: PaneModel(previewing: .failed("the connection closed before this finished")),
        isActive: true
    )
}

/// The host would not report a layout, so the stream was opened at the phone's
/// width against a wider pane — the one case where something really is hidden.
#Preview("Cropped", traits: .sampleData) {
    PaneSurface(
        model: PaneModel(
            previewing: .live,
            grid: TerminalGrid(cols: 53, rows: 40),
            paneGrid: nil
        ),
        isActive: true
    )
}
#endif
