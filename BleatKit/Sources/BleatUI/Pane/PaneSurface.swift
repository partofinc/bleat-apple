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
        #if canImport(UIKit) && !os(watchOS)
        // **The safe area is respected, deliberately.** Extending under it
        // looked tidier — the terminal's black reaching the bottom of the glass
        // — but the pane's last row is its input line, and the home indicator
        // sits on top of it. A terminal's bottom row is the one that matters
        // most; there is nothing to gain by hiding it.
        // **`&& isActive`, or the keyboard outlives the terminal.** Switching
        // to chat leaves this surface mounted at `opacity(0)`, which does not
        // resign first responder — so the keyboard stayed up over the
        // transcript with its only dismiss button hidden behind it, and
        // anything typed still went to the live agent. Reading it here also
        // puts it in a body, which is what makes SwiftUI observe it.
        TerminalHost(
            model: model,
            isActive: isActive,
            wantsKeyboard: model.wantsKeyboard && isActive
        )
            .background(.black)
            // Installed on the terminal itself rather than the whole surface,
            // so the overlays keep their own taps.
            .paneScrollGesture(model)
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
            // **Insetting is not free.** `PaneTerminalController` sets
            // `terminalView.frame = view.bounds` and the pty is resized to
            // match, so the bar really does change the grid (measured: 46 rows
            // without it, 43 with). It is shown unconditionally now that the
            // terminal always holds the pane, which is what makes that cost a
            // constant rather than a reopen on every take and release.
            // **Never gate it on `phase`, and that is not a simplification.**
            // This bar takes space, and `PaneTerminalController`
            // derives the grid from its own bounds, so showing it makes the
            // terminal shorter, which reports a new grid, which reopens the
            // stream and `stty`s the pane. Adding `phase == .live` to this
            // condition therefore built a loop: bar shows → terminal shrinks →
            // reopen → `.opening` → bar hides → terminal grows → reopen →
            // `.live` → bar shows, forever, with a write to the user's Mac on
            // every pass. It reached a device as a spinner that never stopped.
            //
            // The state overlays above switch on `phase` safely because an
            // `.overlay` draws without changing layout. Anything in a safe
            // area is layout, and layout here is the stream's size.
            .safeAreaBar(edge: .bottom) {
                // Shown always, keyboard or not. SwiftUI's
                // keyboard avoidance lifts a safe-area bar clear of the
                // keyboard by itself, so this is also the bar that rides above
                // the keys — there is no second copy and nothing to keep in
                // step. It was an `inputAccessoryView` for a day; on a device
                // that put the keys at the far edge of the screen, a reach away
                // from the arrows they belong beside.
                PaneKeyBar(model: model, isActive: isActive)
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
#endif
