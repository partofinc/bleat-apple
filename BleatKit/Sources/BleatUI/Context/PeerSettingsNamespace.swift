import SwiftUI

extension EnvironmentValues {
    /// The namespace the peer settings sheet is presented in, published
    /// downwards so the button that opens it can be what it grows out of.
    ///
    /// `matchedTransitionSource` and `navigationTransition` have to name the
    /// same `Namespace.ID`, and a `@Namespace` belongs to the view that
    /// declares it. On `PeersView` both halves are in one file, so the device
    /// key sheet can simply declare one. This sheet cannot: it is presented at
    /// the root — one presentation for the two places that open it, see
    /// `PeerSettingsFlow` — while the gear that opens it is two screens down.
    /// So the view that owns the presentation owns the namespace and hands it
    /// to whoever wants to be the source.
    ///
    /// **Optional because a source is optional.** Nothing publishes one in a
    /// preview of `PeerDetailView` on its own, and the swipe on the peer list
    /// has no gear to grow out of. A zoom whose source is not on screen falls
    /// back to the ordinary sheet presentation, so the absent case needs no
    /// handling beyond not claiming to be a source.
    @Entry var peerSettingsNamespace: Namespace.ID?
}
