import SwiftUI
import Testing
@testable import BleatUI

/// The two rules the split view put on the router.
///
/// Both are about the *stack* surviving something it should not: the drill-down
/// belongs to one host, and there are now two ways for that host to change
/// underneath it — the sidebar selection moving, and a host being unpaired by a
/// swipe while a different one is on screen.
@Suite("Navigation router")
struct NavigationRouterTests {

    private func browsing(_ hostKey: String, deep: Int = 2) -> NavigationRouter {
        let router = NavigationRouter()
        router.selectedPeer = hostKey
        for i in 0..<deep {
            router.push(.workspaces(peer: hostKey, session: "s\(i)"))
        }
        return router
    }

    /// The detail column is evaluated from the selection and the path
    /// together, so clearing the path in an `onChange` would draw one host's
    /// workspaces under another host's name for a frame. It has to happen in
    /// the same write.
    @Test("picking another host empties the stack")
    func switchingHostsClearsThePath() {
        let router = browsing("ssh-ed25519 AAAA")
        #expect(router.path.count == 2)

        router.selectedPeer = "ssh-ed25519 BBBB"
        #expect(router.path.isEmpty)
        #expect(router.selectedPeer == "ssh-ed25519 BBBB")
    }

    /// Going back to no host at all is the same rule, and it is also what
    /// releases the connection — see `RootView`.
    @Test("clearing the selection empties the stack")
    func deselectingClearsThePath() {
        let router = browsing("ssh-ed25519 AAAA")
        router.selectedPeer = nil
        #expect(router.path.isEmpty)
    }

    /// Writing the same host key again is not a change, and must not be
    /// treated as one: a `List(selection:)` re-asserting its value would
    /// otherwise throw away the screens the user is standing on.
    @Test("selecting the host already on screen leaves the stack alone")
    func reselectingTheSameHostKeepsThePath() {
        let router = browsing("ssh-ed25519 AAAA")
        router.selectedPeer = "ssh-ed25519 AAAA"
        #expect(router.path.count == 2)
    }

    /// **The case the sidebar created.** Before, unpairing popped
    /// unconditionally, which was right when the only way to reach the unpair
    /// swipe was a peer list with nothing pushed over it. With the host list
    /// permanently on screen, a swipe can unpair a host nobody is looking at.
    @Test("unpairing a host nobody is browsing leaves the screens alone")
    func leavingAnotherHostChangesNothing() {
        let router = browsing("ssh-ed25519 AAAA")
        router.leave("ssh-ed25519 BBBB")
        #expect(router.selectedPeer == "ssh-ed25519 AAAA")
        #expect(router.path.count == 2)
    }

    /// The other half: a pane view left on top of a host that has just stopped
    /// existing would go on asking a connection that is gone.
    @Test("unpairing the host on screen leaves its screens")
    func leavingTheHostOnScreenPops() {
        let router = browsing("ssh-ed25519 AAAA")
        router.leave("ssh-ed25519 AAAA")
        #expect(router.selectedPeer == nil)
        #expect(router.path.isEmpty)
    }

    @Test("pop takes one screen, and does nothing at the root")
    func pop() {
        let router = browsing("ssh-ed25519 AAAA")
        router.pop()
        #expect(router.path.count == 1)
        router.pop()
        router.pop()
        #expect(router.path.isEmpty)
        // Still on the host — popping the stack is not leaving it.
        #expect(router.selectedPeer == "ssh-ed25519 AAAA")
    }
}
