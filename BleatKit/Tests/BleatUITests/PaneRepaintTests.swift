#if canImport(UIKit)
import BleatKit
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import BleatUI

/// Whether a frame that arrives actually reaches the screen.
///
/// **Found on a device, and the trace is why this suite exists.** Typing into a
/// held pane landed on the host and came back as frames — logged arriving, and
/// handed to the terminal — while the screen sat unchanged until the pane was
/// reopened. Delivery was never the problem, so no test that stops at "the
/// bytes were fed" could have caught it. `rangeChanged` fires from inside
/// SwiftTerm's own `updateDisplay`, which makes it the one thing observable
/// from out here that says a repaint really ran.
@Suite("Repainting a pane", .serialized)
@MainActor
struct PaneRepaintTests {

    /// Real frames off a real `terminal session control --takeover` stream,
    /// captured while typing. They carry synchronized-output markers
    /// (`ESC[?2026h`/`l`), which is the part a synthesised frame would miss —
    /// SwiftTerm suppresses every repaint while that mode is open.
    private func capturedFrames() throws -> [Data] {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Fixtures/terminal-control-typing.ndjson")
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .compactMap { line in
                guard
                    let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                    let base64 = object["bytes"] as? String
                else { return nil }
                return Data(base64Encoded: base64)
            }
    }

    /// Hosts the controller in a key window, as `PreviewSmokeTests` does: a
    /// view merely given a frame never lays out, and a terminal that never laid
    /// out cannot repaint either.
    private func hosted(height: CGFloat = 700) -> (PaneTerminalController, UIWindow) {
        let controller = PaneTerminalController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: height))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        return (controller, window)
    }

    /// SwiftTerm's repaint is scheduled a frame later, so nothing here can
    /// assert synchronously.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(120))
    }

    @Test("a frame repaints the terminal")
    func framesRepaint() async throws {
        let frames = try capturedFrames()
        #expect(frames.count > 1, "the fixture lost its frames")

        let (controller, window) = hosted()
        defer { window.isHidden = true }

        controller.feedForTesting(frames[0])
        await settle()
        let afterFirst = controller.repaints
        #expect(afterFirst > 0, "the opening frame never repainted")

        controller.feedForTesting(frames[1])
        await settle()
        #expect(controller.repaints > afterFirst, "a delta frame never repainted")
    }

    /// **The device case.** With the keyboard up the terminal is frozen at its
    /// full height and translated so its bottom sits above the keyboard, which
    /// leaves it taller than the view it lives in and its origin negative.
    /// Frames must still repaint through that.
    @Test("frames repaint while the keyboard holds the grid frozen")
    func repaintsWhileFrozen() async throws {
        let frames = try capturedFrames()
        let (controller, window) = hosted()
        defer { window.isHidden = true }

        controller.feedForTesting(frames[0])
        await settle()

        // Raise the keyboard: freeze, then shrink the view as the system does.
        controller.wantsKeyboard = true
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 381)
        window.layoutIfNeeded()
        await settle()

        let before = controller.repaints
        for frame in frames.dropFirst() {
            controller.feedForTesting(frame)
            await settle()
        }
        #expect(
            controller.repaints > before,
            "no frame repainted while the keyboard was up (\(before) repaints before, \(controller.repaints) after)"
        )

        // **Repainting is not the same as showing the new output.** herdr sends
        // absolute cursor positioning against the live screen, so the drawn
        // viewport has to be sitting on it. `ensureCaretIsVisible()` is what
        // normally keeps it there — and it returns early while synchronized
        // output is active, which for herdr's frames is always.
        let scroll = controller.scrollStateForTesting
        #expect(
            !scroll.canScroll || scroll.position >= 0.999,
            "the viewport drifted off the live screen: position \(scroll.position), canScroll \(scroll.canScroll)"
        )
    }
}
#endif
