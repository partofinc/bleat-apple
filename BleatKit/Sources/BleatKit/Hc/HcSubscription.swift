import Foundation

/// An `events.subscribe` on a framed connection: the snapshot it answered with,
/// and every notification after it.
public struct HcSubscription: Sendable {
    /// `{channel, seq, terminals}`: hand it to `HcTerminalSet.reset(to:)`.
    public let snapshot: HcJSON
    public let notifications: AsyncThrowingStream<HcNotification, any Error>
}

/// One line on a subscription's channel (live, hc 0.1.20).
public enum HcNotification: Sendable, Equatable {
    /// `{type, terminal, seq, data}`: hand it to `HcTerminalSet.apply(event:)`.
    case event(HcJSON)
    /// The subscriber fell behind; a fresh `{seq, terminals}` replaces the
    /// backlog.
    case missed(HcJSON)
    /// Every 15 s, carrying the current `seq`.
    case heartbeat
    /// A method this build does not know. Skipped, never fatal.
    case other(String)
}

extension HcClient {
    /// Subscribes to every terminal's facts.
    ///
    /// - Parameter params: the schema's filters — `terminal`, `labels`,
    ///   `children_of`. Empty for everything.
    public func subscribe(_ params: [String: HcJSON] = [:]) async throws -> HcSubscription {
        let result = try await call("events.subscribe", params)
        guard let channel = result["channel"]?.number else { throw HcProtocolError.notFramed }
        let raw = self.channel(UInt32(channel))
        let notifications = AsyncThrowingStream<HcNotification, any Error> { continuation in
            let task = Task {
                var splitter = NDJSONSplitter()
                let decoder = JSONDecoder()
                do {
                    for try await chunk in raw {
                        for line in try splitter.push(chunk) {
                            // A line that does not parse is skipped: the next
                            // `missed` snapshot repairs anything it carried.
                            guard let message = try? decoder.decode(HcJSON.self, from: line) else { continue }
                            continuation.yield(HcNotification(message))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return HcSubscription(snapshot: result, notifications: notifications)
    }
}

extension HcNotification {
    init(_ message: HcJSON) {
        let params = message["params"] ?? .null
        switch message["method"]?.string {
        case "event": self = .event(params)
        case "missed": self = .missed(params)
        case "heartbeat": self = .heartbeat
        case let other: self = .other(other ?? "")
        }
    }
}
