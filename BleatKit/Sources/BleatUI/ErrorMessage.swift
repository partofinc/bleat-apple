import Foundation

/// Turns a thrown error into something worth showing a user.
///
/// Most of Bleat's errors describe themselves — `HerdrError`, `TransportError`
/// and `PairingError` all conform to `CustomStringConvertible`, and their text
/// is written for this. Two do not, and both would otherwise reach the screen
/// as developer output.
enum ErrorMessage {
    static func of(_ error: any Error) -> String {
        switch error {
        case is DecodingError:
            // A multi-line dump of coding keys otherwise. This is CLAUDE.md's
            // third error class — contract drift — and the actionable form of
            // it names the likely cause rather than the field that failed.
            "the host sent a reply Bleat could not read; it may be running a different version of herdr"
        case is CancellationError:
            // Reaches a screen only if something shows it despite the screen
            // having gone away. `CancellationError()` is not a sentence.
            "cancelled"
        default:
            String(describing: error)
        }
    }
}
