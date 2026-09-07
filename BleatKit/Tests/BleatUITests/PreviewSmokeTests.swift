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
/// The seam itself — a seeded `RemoteList` that does not fetch, a parked
/// `PaneModel` that does not open a stream — is asserted directly, in
/// `previewingListIsInert` and `parkedModels`. The render tests are the second
/// half of that: they put each screen through a **real appearance lifecycle**,
/// so the `.task` modifiers that do the fetching actually run. Without a window
/// they do not run at all, which made an earlier version of this suite pass
/// whether the seam worked or not — verified with a probe view whose only
/// content was a `.task`: false before and after a sleep, hosted bare; true
/// immediately, hosted in a key window.
@Suite("Previews render", .serialized)
@MainActor
struct PreviewSmokeTests {

    /// The context the `.sampleData` trait injects, built the same way.
    private func sampleContext(peers: [PairedPeer] = PairedPeer.samples) -> AppContext {
        let store = PeerStore(registry: .sample(peers))
        store.reload()
        return AppContext(peers: store)
    }

    /// Gives anything the tasks started a moment to land, then checks nothing
    /// connected.
    ///
    /// The wait is what gives this teeth. A dial is asynchronous, so asserting
    /// the instant a render returns would pass even for a screen that had just
    /// started one — and `PairedPeer.preview` carries this Mac's real LAN
    /// address, so on the network these tests run on, a broken seam really does
    /// reach a host that answers.
    private func settle(_ context: AppContext) async {
        try? await Task.sleep(for: .milliseconds(750))
        #expect(context.connections.endpoint == nil, "a preview screen opened a connection")
    }

    /// Hosts a view at iPhone size, in a key window, and forces a layout pass.
    ///
    /// **The window is what makes this a test.** A hosting controller whose
    /// view is merely given a frame evaluates the body but never appears, so
    /// its `.task` modifiers never run — and `.task` is where every screen here
    /// loads. In a key window they run, synchronously enough that they have
    /// already started by the time `layoutIfNeeded` returns.
    ///
    /// Which is also why the seam has to hold: `PairedPeer.preview` has this
    /// Mac's real LAN address on it, so a broken seam would not merely fail —
    /// it would open an SSH connection from the test suite. No test touches the
    /// network.
    private func render(_ context: AppContext, _ view: some View) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 759))
        window.rootViewController = UIHostingController(rootView: view.environment(context))
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
    }

    @Test("the sample context has the hosts the previews are drawn against")
    func sampleData() {
        let context = sampleContext()
        #expect(context.peers.peers.count == 3)
        #expect(context.peers.failure == nil)
        #expect(context.peers.peers.contains { $0.name == "rawillk.air" })
    }

    /// **The location, not the contents.** `AddEndpointView` and the unpair
    /// flow both write, so a preview pointed at `applicationSupport()` edits
    /// the device's own peer list from the canvas — which an earlier version of
    /// that view's preview did. Asserting on the peers cannot catch it: they
    /// are seeded into whatever registry `sample()` is handed, so the same
    /// three hosts appear either way. Only the path tells the two apart.
    @Test("the sample registry is in the temporary directory, never the app's own")
    func sampleRegistryIsThrowaway() {
        let path = PeerRegistry.sample().fileURL.path
        #expect(path.hasPrefix(NSTemporaryDirectory()), "sample registry at \(path)")
        #expect(path != PeerRegistry.applicationSupport().fileURL.path)
        // Distinct per call, so one preview does not rebuild the file another
        // is editing.
        #expect(PeerRegistry.sample().fileURL != PeerRegistry.sample().fileURL)
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

    /// **The load-bearing assumption of every render test below.**
    ///
    /// They are only worth anything if the `.task` modifiers run, and hosting a
    /// controller without a window does not run them — measured: a probe view
    /// whose only content was `Text("hi").task { ran = true }` reported false
    /// immediately and still false after a second. If SwiftUI ever changes when
    /// tasks fire, this fails loudly rather than quietly turning the rest of
    /// the suite back into a compile check.
    @Test("rendering runs the screens' tasks")
    func renderRunsTasks() {
        final class Ran: @unchecked Sendable { var value = false }
        let ran = Ran()
        render(sampleContext(), Text("probe").task { ran.value = true })
        #expect(ran.value, "`.task` did not run — the render tests below prove nothing")
    }

    @Test("the peer screens render")
    func peerScreens() async {
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
        await settle(context)
        // Weak on its own — a dial that failed would also leave this nil — but
        // it is free, and `previewingListIsInert` covers the seam properly.
        #expect(context.connections.endpoint == nil)
    }

    @Test("the list screens render in every state")
    func listScreens() async {
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
        await settle(context)
    }

    @Test("the pane screens render")
    func paneScreens() async {
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
        await settle(context)
    }

    /// The modal flows, whose interesting states are the ones a working host
    /// never produces.
    @Test("the pairing and unpair sheets render")
    func sheets() async {
        let context = sampleContext()
        // `.waiting` is rendered through `PairingCaptureView` with the camera
        // answered rather than asked: the phase's own preview mounts a capture
        // session where access is already granted, and a test must not.
        render(context, NavigationStack {
            PairingCaptureView(model: PairingModel(previewing: .waiting), previewCamera: false)
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
