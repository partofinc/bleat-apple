import BleatKit
import SwiftUI

/// One named Herdr session.
struct SessionRow: View {
    let session: SessionInfo

    var body: some View {
        Label {
            #if os(watchOS)
            // Stacked: three things side by side do not fit a watch, and the
            // name is the one that must not be the thing that wraps.
            VStack(alignment: .leading) {
                Text(session.name)
                    .lineLimit(1)
                Text(session.running ? "running" : "stopped")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            #else
            HStack {
                Text(session.name)
                if session.isDefault {
                    Text("default")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(session.running ? "running" : "stopped")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            #endif
        } icon: {
            // The filled dot carries the same fact as the word beside it, so
            // the distinction does not rest on colour alone.
            Image(systemName: session.running ? "circle.fill" : "circle")
                .foregroundStyle(session.running ? .green : .secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

#if DEBUG
#Preview("Session rows", traits: .sampleData) {
    List {
        ForEach(SessionInfo.samples) { session in
            SessionRow(session: session)
        }
    }
}
#endif
