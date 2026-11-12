import Foundation

/// Something that can open a byte stream to herdr-core: `hc connect` over SSH
/// today, a local socket or a relay later.
///
/// The byte stream is a `DuplexStream` because that is already "raw stdout in,
/// stdin out" — `SSHStream` hands its chunks on untouched. Nothing about it is
/// herdr's but the name.
public protocol HcStreamOpening: Sendable {
    /// - Parameter hcPath: Absolute, as `HerdrCoreCheck` recorded it.
    func openHcConnection(hcPath: String) async throws -> any DuplexStream
}
