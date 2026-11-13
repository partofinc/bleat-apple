import Foundation

/// A subscription read as the terminal set it keeps: the snapshot first, then
/// the set again after every event that changed it, and afresh after a
/// `missed` snapshot.
///
/// **One loop for every subscriber** — the app's list, a terminal screen
/// following its own terminal, and `bleat terminals --watch`. It had been
/// written three times, and a fix to how events apply would have had to be
/// made in each.
///
/// Pulled, like the notifications under it: credit follows what the caller
/// has taken, so a consumer that stops reading stops the core.
public struct HcTerminalUpdates: AsyncSequence, Sendable {
    public struct Update: Sendable, Equatable {
        public enum Cause: Sendable, Equatable {
            /// The subscription's own snapshot, first.
            case snapshot
            /// An event that changed something: its `type` and terminal.
            case event(type: String, terminal: String)
            /// The core said this subscriber fell behind and sent a fresh snapshot.
            case missed
        }

        public let terminals: HcTerminalSet
        public let cause: Cause
    }

    private let subscription: HcSubscription

    init(_ subscription: HcSubscription) { self.subscription = subscription }

    public func makeAsyncIterator() -> Iterator {
        var set = HcTerminalSet()
        set.reset(to: subscription.snapshot)
        return Iterator(notifications: subscription.notifications.makeAsyncIterator(), set: set)
    }

    public struct Iterator: AsyncIteratorProtocol {
        var notifications: AsyncThrowingStream<HcNotification, any Error>.AsyncIterator
        var set: HcTerminalSet
        var sentSnapshot = false

        public mutating func next() async throws -> Update? {
            try await next(isolation: nil)
        }

        /// On the caller's actor, so the notifications iterator never crosses
        /// to another.
        public mutating func next(isolation actor: isolated (any Actor)?) async throws -> Update? {
            if !sentSnapshot {
                sentSnapshot = true
                return Update(terminals: set, cause: .snapshot)
            }
            while let notification = try await notifications.next(isolation: actor) {
                switch notification {
                case .event(let params):
                    guard set.apply(event: params) else { continue }
                    return Update(terminals: set, cause: .event(
                        type: params["type"]?.string ?? "?", terminal: params["terminal"]?.string ?? "?"
                    ))
                case .missed(let snapshot):
                    set.reset(to: snapshot)
                    return Update(terminals: set, cause: .missed)
                case .heartbeat, .other:
                    continue
                }
            }
            return nil
        }
    }
}

extension HcSubscription {
    /// The terminal set after the snapshot and after every change.
    public var updates: HcTerminalUpdates { HcTerminalUpdates(self) }
}
