import Foundation

/// A one-way latch: every waiter resumes once, when the gate opens.
///
/// Used where a callback thread has to release async waiters — the writer
/// becoming available, or a close being requested. Opening twice is harmless.
final class AsyncGate: @unchecked Sendable {
    private enum State {
        case closed([CheckedContinuation<Void, Never>])
        case open
    }

    private let state = LockedBox<State>(.closed([]))

    var isOpen: Bool {
        state.withLock { if case .open = $0 { true } else { false } }
    }

    func open() {
        let waiters = state.withLock { current -> [CheckedContinuation<Void, Never>] in
            guard case .closed(let pending) = current else { return [] }
            current = .open
            return pending
        }
        for waiter in waiters { waiter.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeNow = state.withLock { current -> Bool in
                guard case .closed(var pending) = current else { return true }
                pending.append(continuation)
                current = .closed(pending)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }
}
