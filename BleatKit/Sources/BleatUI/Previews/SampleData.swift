#if DEBUG
import BleatKit
import SwiftUI

/// `#Preview(traits: .sampleData)` — an `AppContext` with hosts in it.
///
/// Every screen in this app reads `AppContext` from the environment, so without
/// this a preview of anything above a row crashes on the missing value. What it
/// injects is a real context over a **throwaway** `PeerRegistry` in the
/// temporary directory, so a preview cannot read the device's actual peer list
/// and cannot write to it either.
///
/// **No preview reaches the network.** The context is real, which means
/// `ConnectionStore` is too, and it would happily dial if a screen asked. It
/// never gets the chance: the screens that fetch take a preview-only
/// initialiser that hands them a `RemoteList` which is already loaded and whose
/// `load` does nothing. That is the seam — see `RemoteList.init(previewing:)`.
/// A preview that dialled would sit on a spinner for a connect timeout and then
/// render a connection error, which is not the screen anyone opened the canvas
/// to look at.
struct SampleData: PreviewModifier {
    /// Hosts to seed. `nil` uses `PairedPeer.samples`.
    let peers: [PairedPeer]?

    init(peers: [PairedPeer]? = nil) { self.peers = peers }

    static func makeSharedContext() async throws {}

    func body(content: Content, context: Void) -> some View {
        SampleContextHost(peers: peers ?? PairedPeer.samples) { content }
    }
}

extension PreviewTrait where T == Preview.ViewTraits {
    /// Three paired hosts, and a context that can be read but will not dial.
    static var sampleData: Self { .modifier(SampleData()) }

    /// The same context with nothing paired, for the empty state — which is the
    /// first screen anyone sees on a fresh install and so is worth being able
    /// to look at.
    static var noHosts: Self { .modifier(SampleData(peers: [])) }
}

/// Owns the context so it survives re-evaluation.
///
/// `@State` rather than building one in `body`: a fresh `AppContext` on every
/// pass would reset the navigation path and the routers, so pushing a screen in
/// the canvas would immediately undo itself.
private struct SampleContextHost<Content: View>: View {
    @State private var context: AppContext
    private let content: Content

    init(peers: [PairedPeer], @ViewBuilder content: () -> Content) {
        let store = PeerStore(registry: .sample(peers))
        store.reload()
        _context = State(wrappedValue: AppContext(peers: store))
        self.content = content()
    }

    var body: some View {
        content.environment(context)
    }
}

/// Hands a preview body the context the trait injected.
///
/// For the few previews that need to *construct* something from it — a
/// `ConnectionStore`, say — since a `#Preview` closure has no environment of
/// its own to read.
struct PreviewContext<Content: View>: View {
    @Environment(AppContext.self) private var context
    @ViewBuilder let content: (AppContext) -> Content

    var body: some View { content(context) }
}
#endif
