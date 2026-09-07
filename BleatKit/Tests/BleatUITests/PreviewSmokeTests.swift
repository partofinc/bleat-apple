#if canImport(UIKit)
import BleatKit
import SwiftUI
import Testing
import UIKit
@testable import BleatUI

/// Every `#Preview`, laid out for real.
///
/// **A preview that compiles can still trap at render**, and the ways it does
/// are exactly the ways this app's previews could go wrong: a screen reading
/// `AppContext` out of an environment that has none, or a seeded model whose
/// `load` runs anyway and replaces the state somebody wanted to look at. Both
/// are invisible to `swift build` and neither shows up until the canvas is
/// opened, one preview at a time.
///
/// It also pins the promise the previews are built on: **none of them reaches
/// the network.** `ConnectionStore.endpoint` stays nil through every render
/// below, which is what says no screen dialled.
@Suite("Previews render", .serialized)
@MainActor
struct PreviewSmokeTests {

    /// The context the `.sampleData` trait injects, built the same way.
    private func sampleContext(peers: [PairedPeer] = PairedPeer.samples) -> AppContext {
        let store = PeerStore(registry: .sample(peers))
        store.reload()
        return AppContext(peers: store)
    }

    /// Hosts a view at iPhone size and forces a layout pass — which is what
    /// actually evaluates the body.
    private func render(_ context: AppContext, _ view: some View) {
        let controller = UIHostingController(rootView: view.environment(context))
        controller.view.frame = CGRect(x: 0, y: 0, width: 393, height: 759)
        controller.view.layoutIfNeeded()
    }

    @Test("the sample context has the hosts the previews are drawn against")
    func sampleData() {
        let context = sampleContext()
        #expect(context.peers.peers.count == 3)
        #expect(context.peers.failure == nil)
        // The trait writes to the temporary directory, never the real registry.
        // A preview that edited the device's own peer list would be a bug with
        // consequences outside the canvas — an earlier `AddEndpointView`
        // preview built a plain `PeerStore()`, which is precisely that.
        #expect(context.peers.peers.contains { $0.name == "rawillk.air" })
    }

    @Test("the empty trait has nothing paired")
    func noHosts() {
        #expect(sampleContext(peers: []).peers.peers.isEmpty)
    }

    /// The seam the rest of it rests on. A seeded list must keep its state
    /// through a `load` — every screen here calls one from `.task`.
    @Test("a previewing list does not fetch, and keeps the state it was given")
    func previewingListIsInert() async {
        let list = RemoteList(previewing: Loadable<[Workspace]>.loaded(Workspace.samples))
        await list.load(for: .preview)
        #expect(list.state.value?.count == Workspace.samples.count)

        // A seeded failure is a state somebody wants to see, so it must survive
        // too — `load` moves an empty list to `.loading` on its way in, and
        // returning after that would show a spinner instead.
        let failed = RemoteList(previewing: Loadable<[Workspace]>.failed("nothing answered"))
        await failed.load(for: .preview)
        #expect(failed.state.failureMessage == "nothing answered")
    }

    @Test("the peer screens render")
    func peerScreens() {
        let context = sampleContext()
        render(context, NavigationStack { PeersView() })
        render(sampleContext(peers: []), NavigationStack { PeersView() })
        render(context, NavigationStack {
            PeerDetailView(peer: .preview, previewing: .loaded(SessionInfo.samples))
        })
        render(context, NavigationStack {
            PeerDetailView(peer: .previewSparse, previewing: .loaded([]))
        })
        render(context, AddEndpointView(peer: .preview))
        #expect(context.connections.endpoint == nil)
    }

    @Test("the list screens render in every state")
    func listScreens() {
        let context = sampleContext()
        render(context, NavigationStack {
            WorkspacesView(peer: .preview, session: "work", previewing: .loaded(Workspace.samples))
        })
        render(context, NavigationStack {
            WorkspacesView(peer: .preview, session: "work", previewing: .failed("nothing answered"))
        })
        render(context, NavigationStack {
            AgentsView(
                peer: .preview, session: "work", workspace: "w2", title: "bleat-apple",
                previewing: .loaded(Agent.samples)
            )
        })
        render(context, NavigationStack {
            AgentsView(
                peer: .preview, session: "work", workspace: nil, title: "bleat-apple",
                previewing: .loaded([])
            )
        })
        #expect(context.connections.endpoint == nil)
    }

    @Test("the pane screens render")
    func paneScreens() {
        let context = sampleContext()
        render(context, PaneChatView(
            phase: .loaded(TranscriptEntry.samples), status: .working, step: nil,
            capturedAt: .now, reload: {}, showTerminal: {}
        ))
        render(context, PaneChatView(
            phase: .unavailable("no transcript"), status: nil, step: nil,
            capturedAt: nil, reload: {}, showTerminal: {}
        ))
        render(context, PaneReaderView(
            lines: .loaded(PreviewPaneText.lines), capturedAt: .now, reload: {}
        ))
        render(context, PaneSurface(model: PaneModel(previewing: .live), isActive: true))
        render(context, PaneSurface(model: PaneModel(previewing: .ended), isActive: true))
        render(context, NavigationStack {
            PaneView(peer: .preview, title: "w2:p1", mode: .chat)
        })
        render(context, NavigationStack {
            PaneView(peer: .preview, title: "w2:p1", mode: .reader)
        })
        #expect(context.connections.endpoint == nil)
    }

    /// The modal flows, whose interesting states are the ones a working host
    /// never produces.
    @Test("the pairing and unpair sheets render")
    func sheets() {
        let context = sampleContext()
        render(context, NavigationStack {
            PairingPhaseView(model: PairingModel(previewing: .waiting))
        })
        render(context, NavigationStack {
            PairingPhaseView(model: PairingModel(previewing: .paired(.preview)))
        })
        render(context, NavigationStack {
            PairingPhaseView(model: PairingModel(previewing: .failed("nothing answered")))
        })
        render(context, UnpairSheet(model: UnpairModel(previewing: .working(.preview))))
        render(context, UnpairSheet(model: UnpairModel(previewing: .keyRemains(
            .preview, reason: "nothing answered",
            advice: .revoke(deviceMarker: PairedPeer.preview.deviceMarker, deviceFingerprint: nil)
        ))))
        render(context, UnpairSheet(model: UnpairModel(previewing: .hostRefusedKey(
            .previewSparse,
            advice: .check(deviceMarker: nil, deviceFingerprint: "SHA256:abc")
        ))))
        #expect(context.connections.endpoint == nil)
    }

    /// A parked model must stay parked: `PaneModel.start()` and
    /// `TranscriptModel.follow` are both reachable from a render, and either
    /// one running would open an exec channel from a canvas.
    @Test("the parked models do not open anything")
    func parkedModels() async {
        let pane = PaneModel(previewing: .live)
        pane.show(TerminalGrid(cols: 80, rows: 24))
        #expect(pane.phase == .live)

        let transcript = TranscriptModel(previewing: .loaded(TranscriptEntry.samples), status: .working)
        await transcript.load(for: .preview)
        await transcript.follow(for: .preview)
        #expect(transcript.entries.count == TranscriptEntry.samples.count)
    }
}
#endif
