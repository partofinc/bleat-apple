#if canImport(UIKit)
import SwiftUI
import Testing
import UIKit
@testable import BleatUI

/// Drives the preference from outside the view under test. At file scope
/// because `@Observable` cannot be applied to a type nested privately in a
/// struct — the macro's own extension cannot then see it.
@Observable
@MainActor
final class ColorSchemeBox { var dark = false }

/// The rule `PaneView`'s `preferredColorScheme` depends on.
///
/// `PaneView` goes dark for the terminal and hands the choice back for the
/// chat. The obvious way to write "hand it back" is to read `\.colorScheme` and
/// pass it on — and that latches: `preferredColorScheme` is a preference that
/// travels *up* to the presentation, so what it sets comes back down as the
/// ambient value, and the next evaluation re-asserts the terminal's `.dark`
/// forever. Once the terminal had been opened the chat stayed dark, and popping
/// the screen was the only way out.
///
/// This is `renderRunsTasks`'s kind of test: it pins a SwiftUI behaviour the
/// app's code is written against, so a toolchain that changed it fails here
/// loudly rather than silently making a comment wrong. It cannot drive
/// `PaneView` itself — the mode is private state with no seam — so it puts the
/// two shapes side by side instead. Measured, not reasoned: before the fix the
/// second column below really did read dark.
@Suite("Colour scheme preference", .serialized)
@MainActor
struct ColorSchemeTests {

    private typealias Box = ColorSchemeBox

    /// How it was written: the "not dark" branch passes the ambient scheme on.
    private struct FeedsItselfBack: View {
        @Environment(\.colorScheme) private var scheme
        let box: Box
        var body: some View {
            Text("x").preferredColorScheme(box.dark ? .dark : scheme)
        }
    }

    /// How it is written: no preference at all in the "not dark" branch.
    private struct ReleasesIt: View {
        let box: Box
        var body: some View {
            Text("x").preferredColorScheme(box.dark ? .dark : nil)
        }
    }

    /// Turns the preference on, then off, reporting the style each time. The
    /// window is pinned to light so "off" has an unambiguous right answer.
    private func styles(_ view: (Box) -> some View) -> (on: UIUserInterfaceStyle, off: UIUserInterfaceStyle) {
        let box = Box()
        let host = UIHostingController(rootView: view(box))
        let window = TestWindow.make(frame: CGRect(x: 0, y: 0, width: 393, height: 759))
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = host
        window.makeKeyAndVisible()
        window.layoutIfNeeded()

        box.dark = true
        window.layoutIfNeeded()
        let on = host.traitCollection.userInterfaceStyle

        box.dark = false
        window.layoutIfNeeded()
        return (on, host.traitCollection.userInterfaceStyle)
    }

    @Test("nil releases the preference, and feeding the scheme back does not")
    func nilReleasesThePreference() {
        let released = styles { ReleasesIt(box: $0) }
        #expect(released.on == .dark)
        #expect(released.off == .light, "the screen did not come back out of dark mode")

        // The counter-example, kept because it is what makes the line above
        // worth writing: this is the version that shipped by hand, and it is
        // still dark after the preference is withdrawn.
        let latched = styles { FeedsItselfBack(box: $0) }
        #expect(latched.on == .dark)
        #expect(latched.off == .dark, "the latch this test exists to explain no longer happens")
    }
}
#endif
