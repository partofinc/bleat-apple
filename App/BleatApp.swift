import BleatKit
import BleatUI
import SwiftUI

/// The app target is a shell: build the root state, inject it, show the root
/// view. Everything else lives in BleatKit and BleatUI.
@main
struct BleatApp: App {
    @State private var context: AppContext
    /// Answers the watch. See `WatchRelayHost`.
    private let watch: WatchRelayHost

    init() {
        let context = AppContext(peers: PeerStore())
        _context = State(wrappedValue: context)
        watch = WatchRelayHost(peers: context.peers, reachability: context.reachability)
        // Here, not in a view's task: the system launches the app in the
        // background to deliver a watch's message, and no view appears then.
        watch.start()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(context)
                #if DEBUG
                .task { await DebugLaunch.apply(to: context) }
                #endif
        }
    }
}
