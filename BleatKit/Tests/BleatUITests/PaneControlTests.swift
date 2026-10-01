import BleatKit
import Foundation
import Testing
@testable import BleatUI

/// Input ownership, which is the one thing on this screen that reaches out and
/// changes someone else's machine.
///
/// The terminal always opens `control --takeover`, so whoever is typing at the
/// Mac loses input the moment it is on screen. What is left to guard is that it
/// is *only* while it is on screen: the terminal stays mounted under the chat,
/// and holding the pane through that would take it from the Mac for a whole
/// visit spent reading.
@Suite("Taking a pane's input")
@MainActor
struct PaneControlTests {

    /// A real model against a peer with **no endpoints**, which
    /// `PeerConnection.connect` refuses before it dials anything. So a model
    /// that tries to open a stream fails instead of sitting in `.opening`,
    /// which is what tells "it tried" apart from "it did not" — with no network.
    private func unreachableModel() -> PaneModel {
        let peers = PeerStore(registry: .sample())
        return PaneModel(
            connections: ConnectionStore(peers: peers, reachability: Reachability()),
            peer: PairedPeer(
                hostKey: "ssh-ed25519 AAAA", name: "mac", username: "ravil", endpoints: []
            ),
            session: "scratch",
            target: "w1:p1"
        )
    }

    /// Waits for the model to leave `.opening`, or gives up.
    private func settled(_ model: PaneModel) async -> PaneModel.Phase {
        for _ in 0..<40 where model.phase == .opening {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return model.phase
    }

    /// The control for the test below: a terminal on screen does try to open,
    /// so a model that stays in `.opening` there means it never tried.
    @Test("a terminal on screen takes the pane")
    func activeOpens() async {
        let model = unreachableModel()
        model.show(TerminalGrid(cols: 80, rows: 30))
        #expect(await settled(model) != .opening, "the terminal never tried to open, so the test below proves nothing")
    }

    /// **The guard that matters most now.** A layout pass still reaches a
    /// hidden terminal, and opening from one would take the pane for nobody.
    @Test("a hidden terminal does not take the pane")
    func hiddenDoesNotOpen() async {
        let model = unreachableModel()
        model.setActive(false)
        model.show(TerminalGrid(cols: 80, rows: 30))
        #expect(await settled(model) == .opening, "a hidden terminal opened a stream")
    }

    /// Coming back to the terminal takes the pane again, without waiting for a
    /// layout pass — which reports nothing when the grid is unchanged.
    @Test("showing the terminal again takes the pane back")
    func reactivatingOpens() async {
        let model = unreachableModel()
        model.setActive(false)
        model.show(TerminalGrid(cols: 80, rows: 30))
        model.setActive(true)
        #expect(await settled(model) != .opening, "the terminal did not reopen when it came back")
    }

    /// A keyboard left up over a pane that has been let go of would drop every
    /// keystroke, silently.
    @Test("hiding the terminal puts the keyboard away")
    func hidingDismissesTheKeyboard() {
        let model = PaneModel(previewing: .live)
        model.setWantsKeyboard(true)
        #expect(model.wantsKeyboard)
        model.setActive(false)
        #expect(model.wantsKeyboard == false, "the keyboard outlived the pane it typed into")
    }

    /// Same for leaving the screen entirely.
    @Test("closing puts the keyboard away")
    func closingDismissesTheKeyboard() async {
        let model = PaneModel(previewing: .live)
        model.setWantsKeyboard(true)
        await model.close()
        #expect(model.wantsKeyboard == false)
    }

    /// Input with no stream to carry it is dropped, not queued for whatever
    /// opens next — a key typed seconds ago must not arrive out of context.
    @Test("input without a stream goes nowhere")
    func sendingWithoutAStreamIsInert() async {
        let model = PaneModel(previewing: .live)
        await model.send(.enter)
        await model.send(bytes: Data("rm -rf /".utf8))
        await model.scroll(.up, notches: 5)
        #expect(model.phase == .live, "input disturbed a pane with no stream")
    }
}
