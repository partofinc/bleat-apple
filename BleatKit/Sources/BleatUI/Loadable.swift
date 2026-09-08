/// Why a fetch failed, and whose fault it was.
///
/// **Three causes, because CLAUDE.md names three error classes** — `HerdrError`
/// (the host said no), `TransportError` (the network), `DecodingError` (contract
/// drift) — and a screen that collapses them into one sentence tells the user
/// the wrong thing about two of them. It told a real one: a `phone` session
/// whose server was a protocol version behind answered with exactly what was
/// wrong and how to fix it, and the phone titled it "Could not reach the host"
/// — sending the user to check a network that was working perfectly.
///
/// The same distinction `TransportError.authenticationFailed` exists for, one
/// layer up: reached and refused is not could not reach.
struct LoadFailure {
    enum Cause {
        /// Nothing answered. The network, the host being asleep, or an address
        /// that no longer reaches it.
        case unreachable
        /// The host was reached, ran the command, and reported why it would
        /// not do it. Herdr's own message is usually the whole answer.
        case hostSaidNo
        /// The host answered in a shape this build could not read.
        case unreadable
    }

    let cause: Cause
    /// Already fit to show — see `ErrorMessage`.
    let message: String

    static func unreachable(_ message: String) -> LoadFailure {
        LoadFailure(cause: .unreachable, message: message)
    }

    static func hostSaidNo(_ message: String) -> LoadFailure {
        LoadFailure(cause: .hostSaidNo, message: message)
    }

    static func unreadable(_ message: String) -> LoadFailure {
        LoadFailure(cause: .unreadable, message: message)
    }
}

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
    case failed(LoadFailure)
    /// A refresh failed over a value that had already arrived. Shown as the
    /// value, with the failure alongside it.
    case stale(Value, LoadFailure)

    /// The most recent value, whether or not the latest attempt succeeded.
    var value: Value? {
        switch self {
        case .loaded(let value), .stale(let value, _): value
        case .loading, .failed: nil
        }
    }

    var failure: LoadFailure? {
        switch self {
        case .failed(let failure), .stale(_, let failure): failure
        case .loading, .loaded: nil
        }
    }

    /// A message already fit to show — see `ErrorMessage`, which is where the
    /// errors that do not describe themselves get a sentence.
    var failureMessage: String? { failure?.message }
}
