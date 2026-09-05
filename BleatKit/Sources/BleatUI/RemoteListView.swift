import SwiftUI

/// A `List` over something fetched from a host, with the three states every
/// such list has.
///
/// Written once because the states are the same everywhere and each of them is
/// easy to get subtly wrong: an empty result is not a failure, a failure needs a
/// way back, and neither should look like the other.
struct RemoteListView<Item, Rows: View>: View {
    let state: Loadable<[Item]>
    /// What to say when the host answered and had nothing to report.
    let empty: String
    let retry: () async -> Void
    @ViewBuilder let rows: ([Item]) -> Rows

    var body: some View {
        List {
            if case .loaded(let items) = state {
                rows(items)
            }
        }
        .overlay {
            switch state {
            case .loading:
                ProgressView()
            case .loaded(let items) where items.isEmpty:
                ContentUnavailableView {
                    Label("Nothing here", systemImage: "tray")
                } description: {
                    Text(empty)
                }
            case .failed(let message):
                ContentUnavailableView {
                    Label("Could not reach the host", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try again") { Task { await retry() } }
                }
            case .loaded:
                EmptyView()
            }
        }
    }
}
