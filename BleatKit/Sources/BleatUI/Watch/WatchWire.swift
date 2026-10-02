#if canImport(WatchConnectivity)
import BleatKit
import Foundation

/// The keys the phone and the watch agree on, written once so the two ends
/// cannot spell them differently.
nonisolated enum WatchWire {
    /// In the application context: the paired hosts, as JSON `[PairedPeer]`.
    static let peers = "peers"
    /// In a queued user-info transfer: an encoded `RelayRequest`.
    static let request = "request"

    /// Shrinks a reply before it crosses.
    ///
    /// A message between the two has a size limit the system does not publish
    /// and enforces by failing the send. What crosses is JSON holding base64 —
    /// a conversation's tail is the large one — and that deflates to a
    /// fraction, so the limit is further off than the raw bytes would put it.
    /// One leading byte says which form follows, so a reply that would not
    /// shrink goes as it is.
    static func pack(_ reply: Data) -> Data {
        if let deflated = try? (reply as NSData).compressed(using: .zlib), deflated.length < reply.count {
            return Data([1]) + (deflated as Data)
        }
        return Data([0]) + reply
    }

    /// Nil for bytes `pack` did not make.
    static func unpack(_ packed: Data) -> Data? {
        guard let form = packed.first else { return nil }
        let body = packed.dropFirst()
        switch form {
        case 0: return Data(body)
        case 1: return try? (Data(body) as NSData).decompressed(using: .zlib) as Data
        default: return nil
        }
    }

    static func peers(from context: [String: Any]) -> [PairedPeer]? {
        guard let data = context[peers] as? Data else { return nil }
        return try? JSONDecoder().decode([PairedPeer].self, from: data)
    }
}
#endif
