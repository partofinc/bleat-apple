import Foundation

/// The list's stream did not reach its first snapshot in time: herdr-core
/// never answered the handshake or the subscription on a channel that was
/// open. Without a limit the list said "connecting" for as long as the
/// channel stayed silent (suspected on a phone on adam, 15 Nov 2026).
struct TerminalListStalled: Error, Equatable, CustomStringConvertible {
    let limit: Duration

    var description: String {
        "herdr-core did not answer within \(limit.components.seconds) seconds"
    }
}
