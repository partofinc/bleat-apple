/// Something fetched from the host: in flight, arrived, or failed.
///
/// Shared because every list screen in the app has exactly these three states
/// and a fourth would be a mistake — "empty" is a `loaded` value the view
/// decides how to present, not a state of the fetch.
enum Loadable<Value> {
    case loading
    case loaded(Value)
    /// A message already fit to show. `HerdrError`, `TransportError` and
    /// `PairingError` all describe themselves, so this is `String(describing:)`
    /// of whatever was thrown.
    case failed(String)
}
