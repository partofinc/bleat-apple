import BleatKit
import SwiftUI

/// One pane's live screen.
///
/// Read-only: this is `terminal session observe`, which cannot disturb whoever
/// holds input on the pane. The keyboard, the accessory row and takeover are
/// Phase 3.
struct PaneView: View {
    let title: String
    @State private var model: PaneModel

    init(
        peer: PairedPeer,
        session: String?,
        target: String,
        title: String,
        connections: ConnectionStore
    ) {
        self.title = title
        _model = State(wrappedValue: PaneModel(
            connections: connections, peer: peer, session: session, target: target
        ))
    }

    var body: some View {
        PaneSurface(model: model)
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    // Says what the screen is, not just what it shows. Herdr
                    // allows one input owner per pane, and a user looking at
                    // live output deserves to know they are not it.
                    Label("Read-only", systemImage: "eye")
                        .labelStyle(.titleAndIcon)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .onDisappear { Task { await model.close() } }
    }
}
