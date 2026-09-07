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
struct RemoteListView<Item, Rows: View>: View {
    let state: Loadable<[Item]>
    /// What to say when the host answered and had nothing to report.
    let empty: String
    let retry: () async -> Void
    @ViewBuilder let rows: ([Item]) -> Rows

    var body: some View {
        List {
            // A failed refresh keeps its rows and says so above them, rather
            // than replacing a good list with an error page.
            if case .stale(_, let message) = state {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.footnote)
                }
            }
            if let items = state.value {
                rows(items)
            }
        }
        .overlay {
            if state.value == nil, let message = state.failureMessage {
                ContentUnavailableView {
                    Label("Could not reach the host", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try again") { Task { await retry() } }
                }
            } else if case .loading = state {
                ProgressView()
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
        state: .failed("none of 3 addresses could be reached"),
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
        state: .stale(Workspace.samples, "the connection closed before this finished"),
        empty: "Nothing here.",
        retry: {}
    ) { items in
        ForEach(items) { WorkspaceRow(workspace: $0) }
    }
}
#endif
