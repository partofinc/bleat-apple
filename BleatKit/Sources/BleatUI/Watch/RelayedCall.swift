import BleatKit

/// One herdr-core call made for the watch by the phone (`RelayTransport.call`).
/// A function, so the watch's screens are tested against a script.
typealias RelayedCall = @MainActor @Sendable (_ method: String, _ params: [String: HcJSON]) async throws -> HcJSON

extension ConnectionStore {
    /// herdr-core on `peer`, through the phone: the watch's way in.
    func relayedCall(for peer: PairedPeer) -> RelayedCall {
        { method, params in
            guard let relay = try await self.link(for: peer) as? RelayTransport else {
                throw TransportError.connectionFailed("herdr-core is reached through the iPhone on this device")
            }
            return try await relay.call(method, params)
        }
    }
}
