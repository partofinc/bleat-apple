/// Something fetched from the host.
///
/// Four cases rather than three, because a refresh that fails is not the same
/// as a fetch that never succeeded: the rows on screen are still the best
/// answer anyone has, and replacing an agent list with a full-screen error over
/// one dropped packet is a worse lie than showing slightly old data and saying
/// so.
enum Loadable<Value> {
    case loading
    case loaded(Value)
    /// Nothing has ever arrived, and the last attempt failed.
    case failed(String)
    /// A refresh failed over a value that had already arrived. Shown as the
    /// value, with the failure alongside it.
    case stale(Value, String)

    /// The most recent value, whether or not the latest attempt succeeded.
    var value: Value? {
        switch self {
        case .loaded(let value), .stale(let value, _): value
        case .loading, .failed: nil
        }
    }

    /// A message already fit to show — see `ErrorMessage`, which is where the
    /// two errors that do not describe themselves get a sentence.
    var failureMessage: String? {
        switch self {
        case .failed(let message), .stale(_, let message): message
        case .loading, .loaded: nil
        }
    }
}
