import BleatKit
import SwiftUI

/// One paired host: the sessions running on it.
///
/// Only the sessions. Everything *about* the host — who it logs in as, its host
/// key, where it answers, what it runs, and whether this phone is still paired
/// with it — is in `PeerSettingsView`, opened by tapping the load bar. None of it changes
/// between visits and none of it is what the user came for; keeping it under
/// the list pushed the sessions up against the top of the screen and made a
/// two-item list look like a header for a page of settings.
///
/// What does change by the minute — how busy the machine is — rides in a bar
/// under the list, here and on the two screens below this one. See
/// `HostLoadBarModifier`. On a watch it is the list's first row instead:
/// `HostLoadSection`.
struct PeerDetailView: View {
    @Environment(AppContext.self) private var context
    /// Always current: `RouteView` looks the peer up by host key on every body
    /// evaluation and hands the stored value in, so an edit in the settings
    /// sheet is reflected without this screen tracking the store itself — and a
    /// peer that has been unpaired swaps the whole screen out one level up
    /// rather than needing a fallback here.
    let peer: PairedPeer
    @State private var sessions: RemoteList<SessionInfo>
    /// Owned here rather than by the overlay, so a launch survives the cover
    /// being dismissed on top of it — the reply is what says whether a session
    /// is now running on someone's Mac.
    @State private var newSession: NewSessionModel
    @State private var isNaming = false
    /// The pairing code for another device. A sheet of this screen's own: the
    /// settings sheet has the same button, but the two are never on screen
    /// at once.
    @State private var isInviting = false
    /// Whether this screen has been on screen before, so a return to it can be
    /// told from the first arrival.
    @State private var hasAppeared = false
    /// Starting, stopping and deleting the host's sessions. Owned by the screen
    /// rather than the row, so one confirmation and one failure alert serve the
    /// whole list.
    @State private var control: SessionControlModel

    /// Takes the store rather than reading `AppContext`, so the model exists
    /// from the first body onwards and a refresh cannot rebuild it mid-load.
    init(peer: PairedPeer, connections: ConnectionStore, peers: PeerStore) {
        self.peer = peer
        // No session prefix: `session list` is a client-side command that
        // reports every session regardless of which one is selected.
        _sessions = State(wrappedValue: RemoteList(connections: connections, session: nil) { client in
            let sessions = try await client.sessions()
            // **The one read that can tell a claim has expired.** A session
            // this phone started and somebody else stopped is still claimed
            // until something notices, and what the claim now decides is
            // whether the stop confirmation warns that a session is not ours —
            // the last guard in front of `herdr session stop`. Only the host's
            // own `running` answers that, and here it is.
            await peers.reconcileStartedSessions(with: sessions, forHostKey: peer.hostKey)
            return sessions
        })
        _newSession = State(wrappedValue: NewSessionModel(connections: connections, peers: peers))
        _control = State(wrappedValue: SessionControlModel(connections: connections, peers: peers))
    }

    #if DEBUG
    /// Preview-only: the sessions are handed in and nothing is fetched.
    init(peer: PairedPeer, previewing state: Loadable<[SessionInfo]>) {
        self.peer = peer
        _sessions = State(wrappedValue: RemoteList(previewing: state))
        _newSession = State(wrappedValue: NewSessionModel(previewing: ""))
        _control = State(wrappedValue: SessionControlModel(previewing: .idle))
    }
    #endif

    var body: some View {
        // `RemoteListView` now that this is a whole screen rather than a
        // section above the host's details. The section it used to be drew its
        // own spinner in a row, deliberately, so the details below stayed
        // readable while the host was being reached; with nothing below, the
        // four states belong in the shared list view that the workspaces and
        // agents screens already use — an empty answer that is not a failure, a
        // failure with a way back, and rows that survive a failed refresh.
        RemoteListView(
            state: sessions.state,
            // The watch has no such button: sessions are made on the phone.
            empty: context.isRelayed
                ? "No sessions on this host."
                : "No sessions yet. Start one with the button below.",
            retry: { await load() },
            header: { HostLoadSection(peer: peer) },
            footer: { EmptyView() }
        ) { list in
            // Only over rows, as on the agents screen: a heading above the
            // empty state reads as a list that failed to load.
            if !list.isEmpty {
                Section("Sessions") {
                    ForEach(list) { session in
                        SessionLink(peer: peer, session: session, control: control)
                    }
                }
            }
        }
        .navigationTitle(peer.name)
        // `.bottomBar` is unavailable on macOS, and `BleatUI` builds for both.
        // The `#else` keeps the settings sheet reachable there; without it the
        // macOS build has a peer screen with no way into the peer.
        #if os(iOS)
        .toolbar { bottomBar }
        // A cover rather than an `.overlay`: the bottom bar floats above the
        // screen's content on iOS 26, so an overlay would leave the plus button
        // that opened this undimmed and still tappable. See `NewSessionField`.
        .fullScreenCover(isPresented: $isNaming) {
            NewSessionField(
                model: newSession,
                peer: peer,
                known: sessions.state.value ?? [],
                onStarted: { Task { await sessions.load(for: peer) } }
            )
        }
        .yieldsToPairing(whileBusy: newSession.isStarting, presenting: $isNaming)
        #elseif !os(watchOS)
        .toolbar {
            ToolbarItem(placement: .primaryAction) { pairButton }
        }
        #endif
        #if !os(watchOS)
        .sheet(isPresented: $isInviting) { InviteView(peer: peer) }
        // A `bleat://` link arriving while the code is up is this phone being
        // paired, not pairing; closing the code withdraws its key.
        .yieldsToPairing(whileBusy: false, presenting: $isInviting)
        #endif
        .hostLoadBar(for: peer)
        .sessionControl(control, on: peer) { _ in await sessions.load(for: peer) }
        .refreshable { await load(force: true) }
        .task { await load() }
        // **A pop does not re-run `.task`.** A session stopped or deleted from
        // inside it would still be listed here as it was — and tapping a
        // deleted one pushes a screen that can only error. The first appearance
        // is left to `.task` so the two do not both load on arrival.
        .onAppear {
            defer { hasAppeared = true }
            guard hasAppeared else { return }
            Task { await load() }
        }
    }

    /// The sessions, then how busy the host is.
    ///
    /// **In that order, and the order is the point.** The load is read only
    /// over a connection that is already up — see `HostLoadStore` — and the
    /// sessions' load is what brings it up.
    ///
    /// - Parameter force: a pull-to-refresh, which reads the load again even
    ///   if the last reading is seconds old.
    private func load(force: Bool = false) async {
        await sessions.load(for: peer)
        await context.hostLoad.refresh(for: peer, force: force)
    }

    #if !os(watchOS)
    private var pairButton: some View {
        Button("Pair Another Device", systemImage: "qrcode") { isInviting = true }
    }
    #endif

    #if os(iOS)
    /// **The plus is on the trailing side on every screen that has one** —
    /// here, the session's and the workspace's — so the thumb finds it in one
    /// place all the way down the drill-down. Pairing another device takes
    /// the other corner; the settings are behind the load bar.
    @ToolbarContentBuilder
    private var bottomBar: some ToolbarContent {
        ToolbarItem(placement: .bottomBar) { pairButton }
        ToolbarSpacer(.flexible, placement: .bottomBar)
        ToolbarItem(placement: .bottomBar) {
            Button("Add Session", systemImage: "plus") {
                // Whatever the last attempt said is not about this one.
                newSession.clearFailure()
                isNaming = true
            }
            .buttonStyle(.glassProminent)
        }
    }
    #endif
}

#if DEBUG
/// The screen loads its sessions in `task`, which would mean an SSH connection
/// attempt from the canvas; `init(peer:previewing:)` hands them in instead, so
/// nothing here dials.
#Preview("Peer", traits: .sampleData) {
    NavigationStack {
        PeerDetailView(peer: .preview, previewing: .loaded(SessionInfo.samples))
    }
}

/// A host with nothing running on it, which is the ordinary state of a Mac that
/// has been rebooted — and the one the empty text has to answer.
#Preview("No sessions", traits: .sampleData) {
    NavigationStack {
        PeerDetailView(peer: .previewSparse, previewing: .loaded([]))
    }
}

/// The host could not be reached, so there is no load bar to tap; the
/// settings are a swipe on the host's row in the list.
#Preview("Unreachable", traits: .sampleData) {
    NavigationStack {
        PeerDetailView(
            peer: .previewOverlayOnly,
            previewing: .failed(.unreachable(
                "this host is only reachable over a VPN from here, and nothing answered — check "
                + "that a VPN reaching it is connected on this device"
            ))
        )
    }
}

/// Still connecting.
#Preview("Loading", traits: .sampleData) {
    NavigationStack {
        PeerDetailView(peer: .preview, previewing: .loading)
    }
}

/// A refresh that dropped over sessions that had already arrived. They stay;
/// the failure sits above them.
#Preview("Stale", traits: .sampleData) {
    NavigationStack {
        PeerDetailView(
            peer: .preview,
            previewing: .stale(SessionInfo.samples, .unreachable("the connection closed before this finished"))
        )
    }
}
#endif
