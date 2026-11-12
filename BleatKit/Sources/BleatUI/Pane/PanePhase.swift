import Foundation

/// Where a terminal screen is: what the surface shows over it.
///
/// Shared by both models behind `PaneDriving`, so the views and the protocol
/// name neither of them — and the herdr one can be deleted without a trace.
enum PanePhase: Equatable {
    /// Connecting, or waiting to learn what size to ask for.
    case opening
    case live
    /// The host closed the stream — the program ended, or the terminal went
    /// away. Distinct from a failure: nothing went wrong.
    case ended
    case failed(String)
}
