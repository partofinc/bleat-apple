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
            // **A bar rather than an overlay, so it cannot cover the pane's
            // last row.** That row is the input line — the whole reason this
            // surface respects the safe area instead of extending under it —
            // and a floating pill over the bottom of a terminal would hide
            // exactly the line a dialog's `Enter to confirm` sits on.
            //
            // **Insetting is not free, and it is worth knowing what it
            // costs.** `PaneTerminalController` sets `terminalView.frame =
            // view.bounds` and the pty is resized to match — the outer scroll
            // view and the pane-grid sizing this comment used to describe were
            // deleted when that landed. So the bar really does change the grid
            // (measured: 46 rows without it, 43 with), and taking or releasing
            // control therefore reopens the stream and writes an `stty` to the
            // user's Mac. That is correct rather than wasteful: the terminal
            // genuinely got shorter and the pane must follow.
            //
            // It costs a *second* reopen, though: `takeControl()` and
            // `releaseControl()` each call `start()` themselves, and the layout
            // pass that follows the bar appearing or disappearing reports a new
            // grid and calls it again. The first reader is normally cancelled
            // at the `guard !Task.isCancelled` before `resizePty`, so nothing
            // is written twice — but the gesture is a beat slower than it
            // looks, and reserving the bar's height in both modes is the way to
            // collapse it if that ever matters.
            // **Gated on `control` alone — never on `phase`, and that is not a
            // simplification.** This bar takes space, and `PaneTerminalController`
            // derives the grid from its own bounds, so showing it makes the
            // terminal shorter, which reports a new grid, which reopens the
            // stream and `stty`s the pane. Adding `phase == .live` to this
            // condition therefore built a loop: bar shows → terminal shrinks →
            // reopen → `.opening` → bar hides → terminal grows → reopen →
            // `.live` → bar shows, forever, with a write to the user's Mac on
            // every pass. It reached a device as a spinner that never stopped.
            //
            // `PaneScrollControl` carries the same `phase` test safely because
            // it is an `.overlay`, which draws without changing layout. Anything
            // in a safe area is layout, and layout here is the stream's size.
            .safeAreaBar(edge: .bottom) {
                // Only while this screen owns input: `PaneModel.send` is a no-op
                // while observing, and a row of keys that silently does nothing
                // is worse than no row at all.
                // Not while the keyboard is up: `KeyBarAccessoryView` is
                // carrying the same bar directly above the keys, and SwiftUI's
                // own keyboard avoidance would lift this one to sit right on
                // top of it — two identical bars, stacked.
                //
                // Safe to vary despite everything above, and only because of
                // *when*: the grid is frozen for the whole time the keyboard is
                // up, so this appearing and disappearing cannot report a new
                // size. Outside that window it never changes.
                if model.control == .controlling, !model.wantsKeyboard {
                    PaneKeyBar(model: model)
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
