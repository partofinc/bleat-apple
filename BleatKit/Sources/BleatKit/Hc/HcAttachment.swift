import Foundation

/// What `terminal.attach` answered: the channel the screen arrives on, and the
/// terminal as it stands after the attach.
///
/// From the live reply in `Fixtures/hc-attach.json` (hc 0.1.20):
/// `{channel, automatic_input, resize_notifications, terminal}`. The record
/// already carries the attaching viewer's size — an active attach takes the
/// terminal over at once.
public struct HcAttachment: Sendable, Equatable {
    public let channel: UInt32
    /// Nil when the record is missing or does not read; the channel is what
    /// matters, and the list has the terminal anyway.
    public let terminal: HcTerminal?

    /// - Throws: `DecodingError` when the reply has no usable `channel`: the
    ///   reply's shape has moved, which is contract drift, not a handshake
    ///   problem.
    public init(reply result: HcJSON) throws {
        guard let channel = result["channel"]?.uint32 else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: [],
                debugDescription: "terminal.attach answered without a usable channel"
            ))
        }
        self.channel = channel
        terminal = try? result["terminal"]?.decode(HcTerminal.self)
    }
}
