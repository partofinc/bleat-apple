import BleatKit
import SwiftUI

/// One paired host: the sessions running on it.
///
/// Only the sessions. Everything *about* the host — who it logs in as, its host
/// key, where it answers, and whether this phone is still paired with it — is
/// in `PeerSettingsView` behind the gear. None of it changes between visits and
/// none of it is what the user came for; keeping it under the list pushed the
/// sessions up against the top of the screen and made a two-item list look like
/// a header for a page of settings.
struct PeerDetailView: View {
    @Environment(AppContext.self) private var context
    /// Published by `PeerSettingsFlow`, which presents the sheet at the root.
    @Environment(\.peerSettingsNamespace) private var settingsNamespace
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

    /// Takes the store rather than reading `AppContext`, so the model exists
    /// from the first body onwards and a refresh cannot rebuild it mid-load.
    init(peer: PairedPeer, connections: ConnectionStore) {
        self.peer = peer
        // No session prefix: `session list` is a client-side command that
        // reports every session regardless of which one is selected.
        _sessions = State(wrappedValue: RemoteList(connections: connections, session: nil) {
            try await $0.sessions()
        })
        _newSession = State(wrappedValue: NewSessionModel(connections: connections))
    }

    #if DEBUG
    /// Preview-only: the sessions are handed in and nothing is fetched.
    init(peer: PairedPeer, previewing state: Loadable<[SessionInfo]>) {
        self.peer = peer
        _sessions = State(wrappedValue: RemoteList(previewing: state))
        _newSession = State(wrappedValue: NewSessionModel(previewing: ""))
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
            empty: "No sessions yet. Start one with the button below.",
            retry: { await sessions.load(for: peer) }
        ) { list in
            ForEach(list) { session in
                SessionLink(peer: peer, session: session)
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
        #else
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Settings", systemImage: "gearshape") { context.peerSettings.show(peer) }
                    .matchedZoomSource(peer.hostKey, in: settingsNamespace)
            }
        }
        #endif
        .refreshable { await sessions.load(for: peer) }
        .task { await sessions.load(for: peer) }
    }

    #if os(iOS)
    @ToolbarContentBuilder
    private var bottomBar: some ToolbarContent {
        ToolbarItem(placement: .bottomBar) {
            Button("Add Session", systemImage: "plus") {
                // Whatever the last attempt said is not about this one.
                newSession.clearFailure()
                isNaming = true
            }
            .buttonStyle(.glassProminent)
        }
        ToolbarSpacer(.flexible, placement: .bottomBar)
        ToolbarItem(placement: .bottomBar) {
            // Through the router rather than a local `@State` sheet: the peer
            // list behind this screen opens the same settings from a swipe, and
            // two `.sheet` modifiers on one intent is a presentation SwiftUI
            // silently drops. See `PeerSettingsFlow`.
            Button("Settings", systemImage: "gearshape") {
                context.peerSettings.show(peer)
            }
            .matchedZoomSource(peer.hostKey, in: settingsNamespace)
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

/// The host could not be reached. Everything that would help diagnose it is a
/// tap away behind the gear.
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
