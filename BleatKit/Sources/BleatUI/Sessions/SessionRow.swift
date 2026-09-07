import BleatKit
import SwiftUI

/// One named Herdr session.
struct SessionRow: View {
    let session: SessionInfo

    var body: some View {
        Label {
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
