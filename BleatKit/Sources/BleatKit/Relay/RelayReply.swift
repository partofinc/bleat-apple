import Foundation

/// The phone's answer to a `RelayRequest`.
public enum RelayReply: Sendable, Codable, Equatable {
    /// The command's stdout, or nothing for a request that has no output.
    case output(Data)
    case peers([PairedPeer])
    case failed(RelayFailure)
}
