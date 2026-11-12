import BleatKit
import SwiftUI

/// One herdr-core terminal, live, with the key bar under it.
///
/// The 1.x terminal surface (`PaneSurface`: SwiftTerm, the key bar, the scroll
/// gesture), driven by `HcPaneModel` instead of herdr. Terminal only: 1.x's
/// chat reading came from herdr's transcript, which hc does not have.
struct HcTerminalScreen: View {
    let title: String
    @State private var model: HcPaneModel
    @Environment(\.scenePhase) private var scenePhase

    init(peer: PairedPeer, address: String, title: String, connections: ConnectionStore) {
        self.title = title
        _model = State(wrappedValue: HcPaneModel(peer: peer, address: address, connections: connections))
    }

    #if DEBUG
    init(title: String, previewing phase: PanePhase) {
        self.title = title
        _model = State(wrappedValue: HcPaneModel(previewing: phase))
    }
    #endif

    var body: some View {
        PaneSurface(model: model, isActive: true)
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.clear, for: .navigationBar)
            #endif
            .preferredColorScheme(.dark)
            // Back from the background, where iOS took the socket and
            // `RootView` released the connection: attach again by itself.
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active, case .failed = model.phase else { return }
                model.retry()
            }
            // Off screen lets go, so the Mac has its size back; back on
            // screen attaches again. Not `close()`: a covering sheet or an
            // iPad column change takes the screen away and brings it back
            // with its state, and a closed model never attaches again.
            .onAppear { model.setActive(true) }
            .onDisappear { model.setActive(false) }
    }
}

#if DEBUG
#Preview("Live", traits: .sampleData) {
    NavigationStack { HcTerminalScreen(title: "Backend", previewing: .live) }
}

#Preview("Failed", traits: .sampleData) {
    NavigationStack {
        HcTerminalScreen(title: "Backend", previewing: .failed("the connection to herdr-core closed"))
    }
}
#endif
