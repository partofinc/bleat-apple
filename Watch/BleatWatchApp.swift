import BleatKit
import BleatUI
import SwiftUI

/// The watch app is a shell too: the same root view over the same context,
/// with one difference underneath — every host is reached through the phone.
///
/// watchOS gives an ordinary app no direct connection, so there is no SSH
/// here; `WatchLink` carries each command to Bleat on the iPhone, which runs
/// it. See `docs/watch.md`.
@main
struct BleatWatchApp: App {
    @State private var context: AppContext
    private let link: WatchLink

    init() {
        let link = WatchLink()
        let peers = PeerStore()
        self.link = link
        _context = State(wrappedValue: AppContext(peers: peers, relay: link.channel))
        // Here, not in a view's task: the hosts arrive from the phone whether
        // or not a screen is up to ask for them.
        link.start(mirroringInto: peers)
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
