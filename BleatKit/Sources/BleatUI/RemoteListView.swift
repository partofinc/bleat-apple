import SwiftUI
#if DEBUG
import BleatKit
#endif

/// A `List` over something fetched from a host, with the states every such list
/// has.
///
/// Written once because the states are the same everywhere and each is easy to
/// get subtly wrong: an empty result is not a failure, a failure needs a way
/// back, a failure *over* rows that already arrived should not throw them away,
/// and none of them should look like the others.
///
/// **On a watch every state is a row in the list**, where a phone lays the
/// failure and the empty answer over it. An overlay does not scroll, and herdr's
/// own account of a refusal — which is usually the fix — runs to more lines
/// than a watch has. It also has to share the screen with whatever `header`
/// drew, which an overlay centred on the list would sit on top of.
struct RemoteListView<Item, Header: View, Footer: View, Rows: View>: View {
    let state: Loadable<[Item]>
    /// What to say when the host answered and had nothing to report.
    let empty: String
    /// Whether the failure and the empty answer are rows rather than overlays.
    /// Follows the platform; a parameter so both can be laid out anywhere.
    var isInline = WatchLayout.isHere
    let retry: () async -> Void
    /// Sections above the fetched rows, drawn in every state — whether there
    /// is anything to put there is the caller's to decide.
    @ViewBuilder let header: () -> Header
    /// And below them.
    @ViewBuilder let footer: () -> Footer
    @ViewBuilder let rows: ([Item]) -> Rows

    var body: some View {
        List {
            header()
            // A failed refresh keeps its rows and says so above them, rather
            // than replacing a good list with an error page.
            if case .stale(_, let failure) = state {
                Section {
                    Label(failure.message, systemImage: symbol(for: failure.cause))
                        .foregroundStyle(.orange)
                        .font(.footnote)
                }
            }
            if let items = state.value {
                rows(items)
            }
            if isInline {
                if let failure = firstFailure {
                    Section {
                        Label(title(for: failure.cause), systemImage: symbol(for: failure.cause))
                            .font(.headline)
                        Text(failure.message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("Try again") { Task { await retry() } }
                    }
                } else if state.value?.isEmpty == true {
                    Section {
                        Text(empty)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            footer()
        }
        .overlay {
            if case .loading = state {
                ProgressView()
            } else if isInline {
                // Drawn as rows, above.
            } else if let failure = firstFailure {
                ContentUnavailableView {
                    Label(title(for: failure.cause), systemImage: symbol(for: failure.cause))
                } description: {
                    Text(failure.message)
                } actions: {
                    Button("Try again") { Task { await retry() } }
                }
            } else if state.value?.isEmpty == true {
                ContentUnavailableView {
                    Label("Nothing here", systemImage: "tray")
                } description: {
                    Text(empty)
                }
                // Otherwise this covers the whole list and swallows the pull
                // that would re-check — and "no agents are running here" is
                // exactly the message a user wants to refresh out of, having
                // just started one on the host.
                .allowsHitTesting(false)
            }
        }
    }

    /// A failure with no rows under it — the one that is the whole screen.
    private var firstFailure: LoadFailure? {
        state.value == nil ? state.failure : nil
    }

    /// **Only one of these is about the network**, and saying that one over the
    /// other two sends the user to check something that is working. A host that
    /// answered was reached; what it said is in the description right below,
    /// and for herdr that text is usually the fix.
    private func title(for cause: LoadFailure.Cause) -> String {
        switch cause {
        case .unreachable: "Could not reach the host"
        case .hostSaidNo: "Herdr said no"
        case .unreadable: "Could not read the reply"
        }
    }

    private func symbol(for cause: LoadFailure.Cause) -> String {
        switch cause {
        case .unreachable: "exclamationmark.triangle"
        case .hostSaidNo: "exclamationmark.bubble"
        case .unreadable: "questionmark.circle"
        }
    }
}

extension RemoteListView where Header == EmptyView, Footer == EmptyView {
    /// Nothing but the fetched rows.
    init(
        state: Loadable<[Item]>,
        empty: String,
        retry: @escaping () async -> Void,
        @ViewBuilder rows: @escaping ([Item]) -> Rows
    ) {
        self.init(
            state: state, empty: empty, retry: retry,
            header: { EmptyView() }, footer: { EmptyView() }, rows: rows
        )
    }
}

#if DEBUG
/// The four states, previewed on the simplest rows there are. Each is easy to
/// get subtly wrong and none of them should look like the others.
#Preview("Loaded", traits: .sampleData) {
    NavigationStack {
        RemoteListView(state: .loaded(Workspace.samples), empty: "Nothing here.", retry: {}) { items in
            ForEach(items) { WorkspaceRow(workspace: $0) }
        }
    }
}

#Preview("Loading", traits: .sampleData) {
    RemoteListView(state: .loading, empty: "Nothing here.", retry: {}) { (items: [Workspace]) in
        ForEach(items) { WorkspaceRow(workspace: $0) }
    }
}

/// An empty answer is not a failure, and the overlay must not swallow the pull
/// that would re-check.
#Preview("Empty", traits: .sampleData) {
    RemoteListView(
        state: .loaded([]),
        empty: "No workspaces in this session.",
        retry: {}
    ) { (items: [Workspace]) in
        ForEach(items) { WorkspaceRow(workspace: $0) }
    }
}

#Preview("Failed", traits: .sampleData) {
    RemoteListView(
        state: .failed(.unreachable("none of 3 addresses could be reached")),
        empty: "Nothing here.",
        retry: {}
    ) { (items: [Workspace]) in
        ForEach(items) { WorkspaceRow(workspace: $0) }
    }
}

/// Rows that arrived, and a refresh that did not. The banner sits above them
/// rather than replacing them.
#Preview("Stale", traits: .sampleData) {
    RemoteListView(
        state: .stale(Workspace.samples, .unreachable("the connection closed before this finished")),
        empty: "Nothing here.",
        retry: {}
    ) { items in
        ForEach(items) { WorkspaceRow(workspace: $0) }
    }
}

/// A watch's failure: rows under whatever the screen put first, so a long
/// answer from herdr scrolls.
#Preview("Failed, inline", traits: .sampleData) {
    RemoteListView(
        state: .failed(.hostSaidNo("no herdr server is running at …/bleat-test/herdr.sock")),
        empty: "Nothing here.",
        isInline: true,
        retry: {},
        header: { Section { HostLoadBar(load: .sampleLinux, isCompact: true) } },
        footer: { EmptyView() }
    ) { (items: [Workspace]) in
        ForEach(items) { WorkspaceRow(workspace: $0) }
    }
    .frame(width: 190)
}
#endif
