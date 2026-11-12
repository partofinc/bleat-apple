import Foundation

/// A long-lived byte stream with a writable side: a remote program's stdout in,
/// its stdin out. `hc connect` over an exec channel is the one Bleat uses;
/// `HcClient` speaks herdr-core's framed protocol over it.
///
/// Bytes, never text or lines: the framing is the protocol's business, and an
/// exec channel chunks stdout however it likes.
public protocol DuplexStream: Sendable {
    var output: AsyncThrowingStream<Data, any Error> { get }
    func send(_ data: Data) async throws
    func close() async
}
