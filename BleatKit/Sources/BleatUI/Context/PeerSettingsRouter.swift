import BleatKit
import Observation

/// Which peer's settings are open, if any.
///
/// A router rather than a screen's `@State`, for the reason `unpair` is one:
/// the sheet is raised from two screens that are in the navigation stack at the
/// same time — a swipe on the peer list, and the gear on a peer's own screen —
/// and a `.sheet` on each would be two presentations of one intent. SwiftUI
/// raises whichever it reaches first and the other silently does nothing.
@Observable
public final class PeerSettingsRouter {
    /// The peer whose settings are up, by **host key**.
    ///
    /// A host key rather than the record, because the sheet *edits* the record:
    /// adding and removing an address both write, and a captured `PairedPeer`
    /// would be stale the moment the first one landed — the list the user was
    /// looking at would not change. The sheet looks the peer up on every body
    /// evaluation instead, which is what `RouteView` does one level up.
    ///
    /// Settable so `.sheet(item:)` can bind to it: SwiftUI owns dismissal, and
    /// the router has to hear about a swipe-down as much as about the Done
    /// button. `UnpairModel.isConfirming` is settable for the same reason.
    public var peer: HostKey?

    /// A host key, wrapped so `.sheet(item:)` can drive the presentation.
    ///
    /// `item:` rather than `isPresented:` because it comes with an `onDismiss`,
    /// which is what `pendingUnpair` below needs.
    public struct HostKey: Identifiable, Hashable, Sendable {
        public let id: String
    }

    /// An unpair asked for from inside the sheet, to run once it has gone.
    ///
    /// **The sheet cannot start the unpair itself.** Its confirmation dialog is
    /// presented at the root, underneath this sheet, so a dialog raised while
    /// the sheet is still up would be covered by it and never seen — the tap
    /// would look like it did nothing. `PeerSettingsFlow` runs this from the
    /// sheet's `onDismiss`, which fires only once the dismissal has finished.
    private var pendingUnpair: PairedPeer?

    public init() {}

    public func show(_ peer: PairedPeer) {
        self.peer = HostKey(id: peer.hostKey)
    }

    public func close() {
        peer = nil
        // A close that is not an unpair must not leave one armed for the next
        // time the sheet is dismissed.
        pendingUnpair = nil
    }

    /// Closes the sheet and asks for the peer to be unpaired once it has gone.
    public func requestUnpair(_ peer: PairedPeer) {
        pendingUnpair = peer
        self.peer = nil
    }

    /// The unpair the sheet asked for, if it asked. Consumed: a dismissal is
    /// the one moment it applies, and leaving it set would unpair on the next.
    public func takePendingUnpair() -> PairedPeer? {
        defer { pendingUnpair = nil }
        return pendingUnpair
    }
}
