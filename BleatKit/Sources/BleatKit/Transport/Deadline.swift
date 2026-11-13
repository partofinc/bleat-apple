import Foundation

/// Work that must answer in time, whether or not it can be cancelled.
///
/// **Not a task group.** A group waits for every child before it returns, and
/// the work this guards — an `hc` call over an SSH session that died without
/// a word — waits on a continuation that cancellation does not reach. Raced
/// as two loose tasks, the caller gets its answer at the deadline and the
/// stuck one is left to end when its connection is closed.
public enum Deadline {
    public static func run<T: Sendable>(
        within limit: Duration,
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let (answers, continuation) = AsyncStream.makeStream(of: Result<T, any Error>?.self)
        let worker = Task {
            do {
                continuation.yield(.success(try await work()))
            } catch {
                continuation.yield(.failure(error))
            }
            continuation.finish()
        }
        let timer = Task {
            try? await Task.sleep(for: limit)
            continuation.yield(nil)
            continuation.finish()
        }
        defer {
            worker.cancel()
            timer.cancel()
        }
        for await answer in answers {
            guard let answer else {
                throw TransportError.connectionFailed("no answer within \(limit.components.seconds) s")
            }
            return try answer.get()
        }
        throw CancellationError()
    }
}
