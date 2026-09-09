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
        let failed = RemoteList(previewing: Loadable<[Workspace]>.failed(.unreachable("nothing answered")))
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
        // Session rows with the stop/delete swipe armed, on a peer that
        // started two of them from this phone — and one, `phone`, that it did
        // not, which is the row proving the guard.
        render(context, NavigationStack {
            List {
                ForEach(SessionInfo.samples) { session in
                    SessionLink(
                        peer: .previewOwningSessions,
                        session: session,
                        control: SessionControlModel(previewing: .idle)
                    )
                }
            }
        })
        // Naming a new session, in the four states worth looking at: free,
        // taken by a running session, taken by a stopped one, and refused by
        // the host. Rendered bare rather than in its cover — a presentation
        // does not complete inside `layoutIfNeeded`, so covering it would test
        // the cover rather than the field.
        for model in [
            NewSessionModel(previewing: "scratch"),
            NewSessionModel(previewing: "work"),
            NewSessionModel(previewing: "bleat-test"),
            NewSessionModel(previewing: "my session"),
            NewSessionModel(previewing: "work", failure: "herdr server is already running"),
            NewSessionModel(previewing: "scratch", isStarting: true),
        ] {
            render(context, NewSessionField(
                model: model, peer: .preview, known: SessionInfo.samples, onStarted: {}
            ))
        }
        // Naming a new workspace, in the states that matter: a good path, one
        // that cannot work, the host saying there is no such directory, and the
        // one nobody will otherwise ever see — created, somewhere else.
        for model in [
            NewWorkspaceModel(
                previewing: "/Users/ravil/Developer/rawillk/bleat-apple",
                suggestions: Pane.sampleDirectories
            ),
            NewWorkspaceModel(previewing: "Developer/bleat-apple"),
            NewWorkspaceModel(previewing: "~/Developer"),
            NewWorkspaceModel(
                previewing: "/Users/ravil/Developr",
                failure: "There is no directory at /Users/ravil/Developr on this host."
            ),
            NewWorkspaceModel(
                previewing: "/Users/ravil/Developer",
                warning: "Created Developer, but its pane opened in /Users/ravil."
            ),
            NewWorkspaceModel(
                previewing: "/Users/ravil/Developer",
                warning: "the connection closed before this finished"
            ),
            NewWorkspaceModel(previewing: "/Users/ravil/Developer", isCreating: true),
        ] {
            render(context, NewWorkspaceForm(
                model: model, peer: .preview, known: Workspace.samples, onCreated: {}
            ))
        }
        // Starting an agent, in the states that matter: armed, a name herdr's
        // own rule refuses, one already taken, a host with no free pane, the
        // cause read out of the pane, and the ambiguous late arrival.
        for model in [
            NewAgentModel(previewing: "reviewer", pane: "w2:p1", available: Pane.samples),
            NewAgentModel(previewing: "Reviewer", pane: "w2:p1", available: Pane.samples),
            NewAgentModel(
                previewing: "builder", pane: "w2:p1",
                available: Pane.samples, takenNames: ["builder"]
            ),
            NewAgentModel(
                previewing: "reviewer", workspace: "w2",
                workspaceDirectory: "/Users/ravil/Developer/rawillk/bleat-apple"
            ),
            NewAgentModel(
                previewing: "reviewer", workspace: "w2",
                workspaceDirectory: "/Users/ravil/Developer/rawillk/bleat-apple",
                isAddingPane: true
            ),
            NewAgentModel(
                previewing: "reviewer", kind: AgentKind("devin"), pane: "w2:p1",
                available: Pane.samples, failure: "zsh: command not found: devin"
            ),
            NewAgentModel(
                previewing: "reviewer", pane: "w2:p1", available: Pane.samples,
                warning: "claude is running in w2:p1, but it took longer than herdr waited."
            ),
            NewAgentModel(
                previewing: "reviewer", pane: "w2:p1",
                available: Pane.samples, isStarting: true
            ),
        ] {
            render(context, NewAgentForm(model: model, peer: .preview, onStarted: {}))
        }
        render(context, PeerSettingsView(hostKey: PairedPeer.preview.hostKey))
        render(context, PeerSettingsView(hostKey: PairedPeer.previewSparse.hostKey))
        // The host unpaired from underneath the sheet, which the root-level
        // unpair flow can do while it is on screen.
        render(context, PeerSettingsView(hostKey: "ssh-ed25519 not-a-paired-host"))
        await settle(context)
        // Weak on its own — a dial that failed would also leave this nil — but
        // it is free, and `previewingListIsInert` covers the seam properly.
        #expect(context.connections.endpoint == nil)
    }

    @Test("the list screens render in every state")
    func listScreens() async {
        let context = sampleContext()
        // The session screen with its bar in each state: ours and running,
        // ours and stopped, and one this install did not start — which is the
        // guard, and shows no bar at all. These also exercise the screen
        // reading `AppContext` for the router it pops with; a version that
        // reached for a `NavigationRouter` in the environment compiled and
        // trapped here.
        render(context, NavigationStack {
            WorkspacesView(
                peer: .previewOwningSessions, session: "work",
                previewing: .loaded(Workspace.samples),
                status: SessionInfo(name: "work", running: true, isDefault: true)
            )
        })
        render(context, NavigationStack {
            WorkspacesView(
                peer: .previewOwningSessions, session: "bleat-test",
                previewing: .failed(.hostSaidNo("no herdr server is running")),
                status: SessionInfo(name: "bleat-test", running: false, isDefault: false)
            )
        })
        render(context, NavigationStack {
            WorkspacesView(
                peer: .preview, session: "phone",
                previewing: .loaded(Workspace.samples),
                status: SessionInfo(name: "phone", running: true, isDefault: false)
            )
        })
        // Somebody else's session, stopped: Start on its own, over the stopped
        // empty state rather than under the list's `server_not_running` error.
        render(context, NavigationStack {
            WorkspacesView(
                peer: .preview, session: "default",
                previewing: .failed(.hostSaidNo("no herdr server is running")),
                status: SessionInfo(name: "default", running: false, isDefault: true)
            )
        })
        render(context, NavigationStack {
            WorkspacesView(peer: .preview, session: "work", previewing: .loaded(Workspace.samples))
        })
        render(context, NavigationStack {
            WorkspacesView(
                peer: .preview, session: "work", previewing: .failed(.unreachable("nothing answered"))
            )
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
        // The other two failure causes. Each draws a different title and a
        // different symbol, and a symbol that does not exist only shows up in
        // a render.
        render(context, NavigationStack {
            AgentsView(
                peer: .preview, session: "phone", workspace: nil, title: "bleat-apple",
                previewing: .failed(.hostSaidNo("restart the Herdr server before using this command"))
            )
        })
        render(context, NavigationStack {
            AgentsView(
                peer: .preview, session: "work", workspace: nil, title: "bleat-apple",
                previewing: .failed(.unreadable("the host sent a reply Bleat could not read"))
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
        render(context, PaneSurface(model: PaneModel(previewing: .live), isActive: true))
        render(context, PaneSurface(model: PaneModel(previewing: .ended), isActive: true))
        render(context, NavigationStack {
            PaneView(peer: .preview, title: "w2:p1", mode: .chat)
        })
        render(context, NavigationStack {
            PaneView(peer: .preview, title: "w2:p1", mode: .terminal)
        })
        // Holding the pane: the toolbar swaps to Release and the two page keys
        // appear over the terminal. Only reachable through a confirmation on a
        // real host, so a render is the only mechanical check it gets.
        render(context, NavigationStack {
            PaneView(
                peer: .preview, title: "w2:p1", mode: .terminal,
                pane: PaneModel(previewing: .live, control: .controlling)
            )
        })
        render(context, PaneSurface(
            model: PaneModel(previewing: .live, control: .controlling), isActive: true
        ))
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

    /// **The settings sheet must be gone before the unpair starts.**
    ///
    /// `UnpairFlow`'s confirmation dialog is presented at the root, underneath
    /// the sheet, so one raised while the sheet is still up is covered by it
    /// and never seen — the Unpair button would look like it did nothing.
    /// `PeerSettingsFlow` runs the handover from `onDismiss`, which is only
    /// correct if asking for it closes the sheet first.
    @Test("asking to unpair from the settings sheet closes it first")
    func unpairFromSettingsClosesTheSheet() {
        let router = PeerSettingsRouter()
        router.show(.preview)
        #expect(router.peer?.id == PairedPeer.preview.hostKey)

        router.requestUnpair(.preview)
        #expect(router.peer == nil, "the sheet was still up when the unpair was handed over")
        #expect(router.takePendingUnpair()?.hostKey == PairedPeer.preview.hostKey)
        // Consumed: a dismissal is the one moment it applies, and leaving it
        // set would unpair on the next one.
        #expect(router.takePendingUnpair() == nil)

        // An ordinary close must not leave one armed either.
        router.show(.preview)
        router.requestUnpair(.preview)
        router.close()
        #expect(router.takePendingUnpair() == nil, "a close left an unpair armed")
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

        // The newest one that reaches out, and the only one that *writes*: a
        // parked `NewSessionModel` must not launch anything, or opening this
        // preview would start a session on the dev Mac.
        let session = NewSessionModel(previewing: "scratch")
        #expect(await session.start(on: .preview) == false)
        #expect(session.failure == nil, "a parked launch reported a failure, so it tried")

        // The other write, and the one with a directory check in front of it:
        // a parked create must not reach the host for `test -d` either.
        let workspace = NewWorkspaceModel(previewing: "/Users/ravil/Developer")
        #expect(await workspace.create(on: .preview) == .failed)
        #expect(workspace.failure == nil, "a parked create reported a failure, so it tried")

        // The one that starts a *program* in someone's pane, and the slowest
        // to fail: a parked start must not reach the host at all.
        let agent = NewAgentModel(previewing: "reviewer", pane: "w2:p1", available: Pane.samples)
        #expect(await agent.start(on: .preview) == .failed)
        #expect(agent.failure == nil, "a parked start reported a failure, so it tried")

        // And the one that would *end* processes on the dev Mac rather than
        // start them.
        let control = SessionControlModel(previewing: .idle)
        let target = SessionInfo(name: "work", running: true, isDefault: true)
        control.ask(.stop, about: target)
        #expect(await control.perform(.stop, about: target, on: .preview) == false)
    }
}
#endif
