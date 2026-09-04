import BleatKit
import SwiftUI

/// The first screen: which host to reach, and the key this device offers.
public struct HostsView: View {
    @Environment(AppContext.self) private var context
    @State private var showingKey = false

    public init() {}

    public var body: some View {
        List {
            if let failure = context.hosts.failure {
                Section {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }

            Section("Hosts") {
                if context.hosts.hosts.isEmpty {
                    Text("No hosts yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(context.hosts.hosts) { host in
                        Button {
                            context.navigation.push(.sessions(host: host.name))
                        } label: {
                            HostRow(entry: host)
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { offsets in
                        // Snapshot first: `remove` reloads the array, so
                        // indices after the first are stale — a multi-select
                        // delete would remove the wrong host or run off the end.
                        let doomed = offsets.map { context.hosts.hosts[$0] }
                        for entry in doomed { context.hosts.remove(entry) }
                    }
                }
            }

            Section {
                Button("This device's key") { showingKey = true }
            } footer: {
                // Zero host setup beyond Herdr is the product promise, so the
                // one manual step there is gets explained rather than assumed.
                Text("Add this key to the host's ~/.ssh/authorized_keys before connecting.")
            }
        }
        .navigationTitle("Bleat")
        .sheet(isPresented: $showingKey) { DeviceKeyView() }
        .onAppear { context.hosts.reload() }
    }
}

struct HostRow: View {
    let entry: HostEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.name).font(.headline)
            Text(entry.spec).font(.caption).foregroundStyle(.secondary)
            if let session = entry.session {
                Text("session: \(session)").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
