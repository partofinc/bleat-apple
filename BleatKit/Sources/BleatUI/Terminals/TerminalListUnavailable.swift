import Foundation

/// Why the new-terminal sheet's question could not be asked on the list's
/// connection: the list failed, and why; or it is still reconnecting. Said
/// instead of "the connection to herdr-core closed" (from review), which
/// hid a refused key or an old core behind the message the sheet showed
/// when this was found.
enum TerminalListUnavailable: Error, Equatable, CustomStringConvertible {
    case failed(String)
    case reconnecting

    var description: String {
        switch self {
        case .failed(let reason): "the terminal list could not connect: \(reason)"
        case .reconnecting: "the terminal list is still reconnecting to herdr-core"
        }
    }
}
