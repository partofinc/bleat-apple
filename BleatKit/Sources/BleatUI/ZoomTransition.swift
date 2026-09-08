import SwiftUI

/// The two halves of a zoom presentation, each tolerating an absent namespace.
///
/// Both take `Namespace.ID?` because the namespace can travel through the
/// environment — see `EnvironmentValues.peerSettingsNamespace` — and nothing
/// publishes one in a preview of a single screen. A zoom with no source on
/// screen falls back to an ordinary presentation, so the absent case is not an
/// error to report, merely a decoration not to claim.
extension View {
    /// Marks this as the thing a sheet identified by `id` grows out of.
    ///
    /// The branch is safe where most are not: a namespace is published once and
    /// never changes, so the `_ConditionalContent` this builds cannot flip and
    /// take a view's structural identity with it.
    @ViewBuilder
    func matchedZoomSource(_ id: String, in namespace: Namespace.ID?) -> some View {
        if let namespace {
            matchedTransitionSource(id: id, in: namespace)
        } else {
            self
        }
    }

    /// Presents this as a zoom out of the source with the same `id`.
    ///
    /// **`.zoom` is iOS-only**, unlike `matchedTransitionSource`, which
    /// compiles for both — so the platform branch is here rather than at every
    /// call site. `BleatUI` builds for macOS too (`swift build` is what
    /// compiles it that way), and without this the whole module fails there
    /// with `'zoom(sourceID:in:)' is unavailable in macOS`. The Mac simply gets
    /// the standard presentation.
    @ViewBuilder
    func zoomTransition(from id: String, in namespace: Namespace.ID?) -> some View {
        #if os(iOS)
        if let namespace {
            navigationTransition(.zoom(sourceID: id, in: namespace))
        } else {
            self
        }
        #else
        self
        #endif
    }
}
