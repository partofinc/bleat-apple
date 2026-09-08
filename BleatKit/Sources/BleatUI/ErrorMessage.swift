import BleatKit
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

    /// The same message, plus which of CLAUDE.md's three error classes it came
    /// from — so a screen can say whether the host was reached before it says
    /// what went wrong.
    static func failure(of error: any Error) -> LoadFailure {
        switch error {
        case let herdr as HerdrError:
            // The host ran the command and reported why it would not do it.
            // Its own `message` rather than `description`, which prefixes the
            // command and exit code — right in a terminal, noise on a phone,
            // and herdr's text is written for a person: "restart the Herdr
            // server before using this command" is the whole answer.
            .hostSaidNo(herdr.message ?? of(herdr))
        case is DecodingError:
            .unreadable(of(error))
        default:
            // Everything else reaches the user as "nothing answered", which is
            // what `TransportError` means and what a cancelled load looks like.
            .unreachable(of(error))
        }
    }
}
