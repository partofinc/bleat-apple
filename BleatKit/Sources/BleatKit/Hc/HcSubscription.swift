import Foundation

/// An `events.subscribe` on a framed connection: the snapshot it answered with,
/// and every notification after it.
public struct HcSubscription: Sendable {
    /// `{channel, seq, terminals}`: hand it to `HcTerminalSet.reset(to:)`.
    public let snapshot: HcJSON
    public let notifications: AsyncThrowingStream<HcNotification, any Error>
}

extension HcClient {
    /// Subscribes to every terminal's facts.
    ///
    /// - Parameter params: the schema's filters — `terminal`, `labels`,
    ///   `children_of`. Empty for everything.
    public func subscribe(_ params: [String: HcJSON] = [:]) async throws -> HcSubscription {
        let result = try await call("events.subscribe", params)
        guard let channel = result["channel"]?.uint32 else { throw HcProtocolError.notFramed }
        let reader = HcLineReader(self.channel(channel), client: self, channel: channel)
        // Pulled one at a time, so credit follows what the caller has read.
        let notifications = AsyncThrowingStream<HcNotification, any Error> {
            while let line = try await reader.next() {
                // A line that does not parse is skipped: the next `missed`
                // snapshot repairs anything it carried.
                guard let message = try? JSONDecoder().decode(HcJSON.self, from: line) else { continue }
                return HcNotification(message)
            }
            return nil
        }
        return HcSubscription(snapshot: result, notifications: notifications)
    }
}
