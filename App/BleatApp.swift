import BleatKit
import BleatUI
import SwiftUI

/// The app target is a shell: build the root state, inject it, show the root
/// view. Everything else lives in BleatKit and BleatUI.
@main
struct BleatApp: App {
    @State private var context = AppContext(peers: PeerStore())

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(context)
        }
    }
}
