#if canImport(UIKit)
import SwiftUI
import Testing
import UIKit
@testable import BleatUI

/// Why `RootView`'s detail root carries `.id(hostKey)`.
///
/// **This measures SwiftUI, deliberately**, in the way `ColorSchemeTests` does:
/// the line it justifies looks like a no-op, it was left off, and what shipped
/// to the iPad was one host's name over another host's sessions. Keeping the
/// broken shape beside the fixed one is what stops it being "tidied" away
/// again.
///
/// The rule: a view **pushed** onto a stack is a new view with new `@State`,
/// which is what the drill-down relied on before there was a sidebar. A view
/// that is a stack's **root** is reused when its inputs change — same type,
/// same position — so its `@State` survives and a plain `.task` never re-runs,
/// because the view does not re-appear.
@Suite("Switching hosts in the sidebar", .serialized)
@MainActor
struct DetailIdentityTests {

    /// What the view captured into `@State` the first time it was built. It
    /// diverges from what the parent is passing exactly when the view was
    /// reused rather than rebuilt.
    private final class Captured: @unchecked Sendable { var value = "" }

    /// Stands in for `PeerDetailView`, whose `@State` is a `RemoteList` built
    /// from the peer in `init`.
    private struct Screen: View {
        let key: String
        let captured: Captured
        @State private var atInit: String

        init(key: String, captured: Captured) {
            self.key = key
            self.captured = captured
            _atInit = State(wrappedValue: key)
        }

        var body: some View {
            let _ = { captured.value = atInit }()
            Text(atInit)
        }
    }

    /// Stands in for `RootView.detail`.
    private struct Detail: View {
        let key: String
        let captured: Captured
        let identified: Bool

        var body: some View {
            if identified {
                Screen(key: key, captured: captured).id(key)
            } else {
                Screen(key: key, captured: captured)
            }
        }
    }

    /// Builds the root, then swaps the host key underneath it the way the
    /// sidebar's selection does, and reports what the screen is holding.
    private func afterSwitchingHosts(identified: Bool) async -> String {
        let captured = Captured()
        let controller = UIHostingController(
            rootView: Detail(key: "host-A", captured: captured, identified: identified)
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1210, height: 834))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        #expect(captured.value == "host-A", "the first host never rendered")

        controller.rootView = Detail(key: "host-B", captured: captured, identified: identified)
        window.layoutIfNeeded()
        try? await Task.sleep(for: .milliseconds(200))
        window.layoutIfNeeded()
        return captured.value
    }

    /// **The bug, kept.** Without an identity the screen is reused, so it goes
    /// on holding everything it built for the host that has been left.
    @Test("without an identity the detail keeps the previous host's state")
    func reusedWithoutAnIdentity() async {
        #expect(await afterSwitchingHosts(identified: false) == "host-A")
    }

    /// **The fix.** A different host is a different view, which is what a push
    /// gave for free.
    @Test("the host key as an identity rebuilds the detail")
    func rebuiltWithAnIdentity() async {
        #expect(await afterSwitchingHosts(identified: true) == "host-B")
    }
}
#endif
