import Foundation

/// Where a terminal screen is: what the surface shows over it.
///
/// Part of `PaneDriving`, so the views and the protocol name no model.
enum PanePhase: Equatable {
    /// Connecting, or waiting to learn what size to ask for.
    case opening
    case live
    /// The host closed the stream — the program ended, or the terminal went
    /// away. Distinct from a failure: nothing went wrong.
    case ended
    case failed(String)
}
